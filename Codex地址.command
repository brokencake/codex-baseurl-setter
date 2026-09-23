#!/bin/bash
# 自定义 URL 开关 + 模型清单刷新；只修改连接地址和模型清单路径。
# 刷新清单时读取 API Key 仅用于请求模型列表，不显示、不写入、不修改登录凭据。
PY=""
for p in "$(command -v python3)" /opt/miniconda3/bin/python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
  if [ -x "$p" ] && "$p" -c 'import tomllib' 2>/dev/null; then
    PY="$p"
    break
  fi
done
if [ -z "$PY" ]; then
  echo "需要 Python 3.11 或更新版本才能安全检查配置。未做任何修改。"
  read -r -p "回车关闭"
  exit 1
fi

IFS= read -r -d '' CODEX_URL_SCRIPT <<'PYTHON'
import json
import os
import re
import shutil
import stat
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import urlsplit

import tomllib

SAVED_PREFIX = '# codex-url-switch-saved = '
SAVED_CATALOG_PREFIX = '# codex-url-switch-saved-catalog = '
URL_LINE = re.compile(r'''^\s*(?:openai_base_url|"openai_base_url"|'openai_base_url')\s*=''')
CATALOG_LINE = re.compile(r'''^\s*(?:model_catalog_json|"model_catalog_json"|'model_catalog_json')\s*=''')
CODEX_BINARIES = ('/Applications/ChatGPT.app/Contents/Resources/codex',
                  '/Applications/Codex.app/Contents/Resources/codex')


def root_parts(text):
    lines = text.splitlines(keepends=True)
    boundary = next((i for i, line in enumerate(lines)
                     if line.lstrip().startswith('[')), len(lines))
    return lines[:boundary], lines[boundary:]


def saved_value(text, prefix):
    root, _ = root_parts(text)
    for line in root:
        if line.startswith(prefix):
            value = json.loads(line[len(prefix):])
            if not isinstance(value, str):
                raise ValueError('记住的配置格式不正确')
            return value
    return ''


def saved_url(text):
    return saved_value(text, SAVED_PREFIX)


def normalize_url(value):
    value = value.strip().strip('\"\'').strip().rstrip('/')
    if not value:
        raise ValueError('地址不能为空')
    if not re.match(r'^[a-zA-Z][a-zA-Z0-9+.-]*://', value):
        value = 'http://' + value
    parsed = urlsplit(value)
    if (parsed.scheme not in ('http', 'https') or not parsed.hostname
            or parsed.username is not None or parsed.password is not None
            or parsed.query or parsed.fragment
            or any(c.isspace() or ord(c) < 32 for c in value)):
        raise ValueError('请填写 http(s) 地址，不要包含账号、密码、查询参数或空格')
    parsed.port  # 同时检查端口格式及范围。
    return value if parsed.path.endswith('/v1') else value + '/v1'


def catalog_plan(original, target):
    """关闭自定义 URL 时停用并记住模型清单；开启时恢复。返回 (清单, 记住的清单)。"""
    current = tomllib.loads(original).get('model_catalog_json')
    current = current if isinstance(current, str) else ''
    remembered = saved_value(original, SAVED_CATALOG_PREFIX)
    if not target:
        return '', current or remembered
    if current:
        return current, ''
    if remembered and Path(remembered).expanduser().is_file():
        return remembered, ''
    return '', remembered


def updated_text(original, target, remembered, catalog='', saved_catalog=''):
    root, rest = root_parts(original)
    kept = [line for line in root
            if not URL_LINE.match(line) and not line.startswith(SAVED_PREFIX)
            and not CATALOG_LINE.match(line) and not line.startswith(SAVED_CATALOG_PREFIX)]
    prefix = ''
    if remembered:
        prefix += SAVED_PREFIX + json.dumps(remembered, ensure_ascii=False) + '\n'
    if saved_catalog:
        prefix += SAVED_CATALOG_PREFIX + json.dumps(saved_catalog, ensure_ascii=False) + '\n'
    if target:
        prefix += 'openai_base_url = ' + json.dumps(target, ensure_ascii=False) + '\n'
    if catalog:
        prefix += 'model_catalog_json = ' + json.dumps(catalog, ensure_ascii=False) + '\n'
    result = prefix + ''.join(kept + rest)
    before = tomllib.loads(original)
    after = tomllib.loads(result)
    expected = dict(before)
    if target:
        expected['openai_base_url'] = target
    else:
        expected.pop('openai_base_url', None)
    if catalog:
        expected['model_catalog_json'] = catalog
    else:
        expected.pop('model_catalog_json', None)
    if after != expected:
        raise ValueError('配置中包含无法安全处理的地址写法，已停止修改')
    return result


def catalog_text(original, catalog):
    root, rest = root_parts(original)
    kept = [line for line in root
            if not CATALOG_LINE.match(line) and not line.startswith(SAVED_CATALOG_PREFIX)]
    result = ('model_catalog_json = ' + json.dumps(catalog, ensure_ascii=False) + '\n'
              + ''.join(kept + rest))
    expected = dict(tomllib.loads(original))
    expected['model_catalog_json'] = catalog
    if tomllib.loads(result) != expected:
        raise ValueError('配置中包含无法安全处理的清单写法，已停止修改')
    return result


def client_version():
    for binary in CODEX_BINARIES + (shutil.which('codex'),):
        if binary and os.access(binary, os.X_OK):
            try:
                output = subprocess.run([binary, '--version'], capture_output=True,
                                        text=True, timeout=10).stdout
            except (OSError, subprocess.TimeoutExpired):
                continue
            found = re.search(r'(\d+\.\d+\.\d+)', output)
            if found:
                return found.group(1)
    raise ValueError('找不到 Codex 程序，无法确定客户端版本')


def api_key(home):
    try:
        auth = json.loads((home / 'auth.json').read_text(encoding='utf-8'))
    except (OSError, ValueError):
        auth = {}
    key = auth.get('OPENAI_API_KEY')
    if auth.get('auth_mode') != 'apikey' or not isinstance(key, str) or not key:
        raise ValueError('当前不是 API Key 登录。请先在 Codex 中用 API Key 登录，再刷新清单')
    return key


def fetch_catalog(url, key, version):
    request = urllib.request.Request(
        url.rstrip('/') + '/models?client_version=' + version,
        headers={'Authorization': 'Bearer ' + key})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            body = response.read()
    except urllib.error.HTTPError as error:
        hint = '，API Key 不被这个地址接受' if error.code in (401, 403) else ''
        raise ValueError(f'地址返回 HTTP {error.code}{hint}') from None
    except (urllib.error.URLError, OSError) as error:
        raise ValueError(f'连接失败：{getattr(error, "reason", error)}') from None
    try:
        models = json.loads(body)['models']
    except (ValueError, KeyError, TypeError):
        raise ValueError('地址返回的不是 Codex 模型清单格式，未修改') from None
    if (not isinstance(models, list) or not models
            or not all(isinstance(m, dict) and isinstance(m.get('slug'), str) for m in models)):
        raise ValueError('地址返回的模型清单为空或格式不对，未修改')
    return body, models


def visible_slugs(models):
    return [m['slug'] for m in models if m.get('visibility', 'list') == 'list']


def refresh_catalog(config, original, data, current):
    if not current:
        print('自定义 URL 未开启，请先开启再刷新清单。未修改。')
        return
    key = api_key(config.parent)
    version = client_version()
    print(f'\n正在从 {current} 拉取模型清单（客户端版本 {version}）…')
    body, models = fetch_catalog(current, key, version)
    old_path = data.get('model_catalog_json')
    old_models = []
    if isinstance(old_path, str):
        try:
            old_body = Path(old_path).expanduser().read_bytes()
            old_models = json.loads(old_body)['models']
        except (OSError, ValueError, KeyError, TypeError):
            old_body = None
        if old_body == body:
            print('模型清单没有变化，无需修改。')
            return
    folder = config.parent / 'model-catalogs'
    folder.mkdir(exist_ok=True)
    catalog = folder / time.strftime('url-models-%Y%m%d-%H%M%S.json')
    with catalog.open('xb') as handle:
        handle.write(body)
    write_config(config, original, catalog_text(original, str(catalog)))
    print(f'新清单 → {catalog}')
    new_visible = visible_slugs(models)
    old_visible = visible_slugs(old_models) if old_models else []
    added = [s for s in new_visible if s not in old_visible]
    removed = [s for s in old_visible if s not in new_visible]
    print('\n可选模型：' + '、'.join(new_visible))
    if old_models:
        print('新增：' + ('、'.join(added) or '无'))
        print('移除：' + ('、'.join(removed) or '无'))
    model = data.get('model')
    if isinstance(model, str) and model not in [m['slug'] for m in models]:
        print(f'提示：当前默认模型 {model} 不在新清单里，请在 Codex 里重新选择模型。')
    print('\n请用 Cmd+Q 完全退出 Codex，再重新打开。不需要退出登录。')


def write_config(config, original, result):
    if config.read_text(encoding='utf-8') != original:
        raise ValueError('配置已被其他程序更新，请重新打开小工具')
    index = 1
    while config.with_name(f'config.v{index}.toml').exists():
        index += 1
    backup = config.with_name(f'config.v{index}.toml')
    with backup.open('xb') as handle:
        handle.write(config.read_bytes())
    shutil.copystat(config, backup)
    descriptor, temporary = tempfile.mkstemp(prefix='.codex-url-', dir=config.parent)
    try:
        with os.fdopen(descriptor, 'w', encoding='utf-8') as handle:
            handle.write(result)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, stat.S_IMODE(config.stat().st_mode))
        if config.read_text(encoding='utf-8') != original:
            raise ValueError('配置已被其他程序更新，请重新打开小工具')
        os.replace(temporary, config)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(f'\n已备份 → {backup}')
    print('配置语法检查：通过')


def main():
    config = Path(os.environ.get('CODEX_HOME') or Path.home() / '.codex') / 'config.toml'
    if not config.is_file():
        raise ValueError(f'找不到 {config}')
    original = config.read_text(encoding='utf-8')
    data = tomllib.loads(original)
    current = data.get('openai_base_url', '')
    if not isinstance(current, str):
        raise ValueError('当前地址格式不正确')
    remembered = saved_url(original)
    print('============================================')
    print('           Codex 地址开关')
    print('============================================\n')
    print('自定义 URL：' + ('开启' if current else '关闭（默认连接）'))
    print('当前地址：' + (current or '使用 Codex 默认地址'))
    if not current and remembered:
        print('记住的地址：' + remembered)
    print('\n1. ' + ('关闭自定义 URL（用于切换账号登录）' if current
                         else '开启自定义 URL（恢复记住的地址）'))
    print('2. 填写 / 修改自定义 URL 并开启')
    print('3. 从当前地址刷新模型清单（发布新模型后使用）')
    print('0. 退出，不修改\n')
    choice = input('请选择 [0/1/2/3]：').strip()
    if choice in ('', '0'):
        print('已退出，未修改。')
        return
    if choice == '3':
        refresh_catalog(config, original, data, current)
        return
    if choice not in ('1', '2'):
        print('选项无效，未修改。')
        return
    if choice == '1' and current:
        target = ''
        remembered = current
    elif choice == '1' and remembered:
        target = remembered
    else:
        print('\n可只填 IP 和端口，自动补 http:// 和 /v1。直接回车取消。')
        value = input('新地址：')
        if not value.strip():
            print('已取消，未修改。')
            return
        target = normalize_url(value)
        print('将使用：' + target)
        if input('确认保存并开启？[y/N]：').strip().lower() != 'y':
            print('已取消，未修改。')
            return
        remembered = target
    if target == current:
        print('当前已经使用这个地址，无需修改。')
        return
    catalog, saved_catalog = catalog_plan(original, target)
    result = updated_text(original, target, remembered, catalog, saved_catalog)
    write_config(config, original, result)
    old_catalog = data.get('model_catalog_json')
    if not target and old_catalog:
        print('模型清单限制已一并停用（已记住，开启自定义 URL 时自动恢复）。')
    elif target and catalog and catalog != old_catalog:
        print('已恢复模型清单：' + catalog)
    elif target and saved_catalog:
        print('提示：记住的模型清单文件已不存在，可选 3 重新从地址刷新。')
    if target:
        print('\n自定义 URL 已开启：' + target)
        try:
            response = subprocess.run(
                ['curl', '-s', '--max-time', '6', '-o', '/dev/null', '-w', '%{http_code}',
                 target.rstrip('/') + '/models'], capture_output=True, text=True, timeout=8)
            code = response.stdout.strip()
            if code in ('200', '401', '403'):
                print(f'连通测试：服务有响应（HTTP {code}），未验证 API Key。')
            elif code and code != '000':
                print(f'连通测试：HTTP {code}，请检查接口路径。')
            else:
                print('连通测试：暂时无法连接，请检查地址及网络。')
        except (OSError, subprocess.TimeoutExpired):
            print('连通测试未完成；地址已保存。')
    else:
        print('\n自定义 URL 已关闭，原地址已记住，下次选 1 即可恢复。')
    print('\n请用 Cmd+Q 完全退出 Codex，再重新打开。')
    print('这个开关只切换地址，不会自动切换登录方式。')
    if not target:
        print('要用 ChatGPT 账号：在 Codex 中退出当前登录，再选择账号登录。')
        if data.get('forced_login_method') == 'api':
            print('提示：配置还限制了 API 登录，需要取消 forced_login_method 的限制。')
    if data.get('model_provider', 'openai') != 'openai':
        print('提示：当前还选择了其他模型提供商，其地址不受这个开关控制。')


if __name__ == '__main__':
    status = 0
    try:
        main()
    except (EOFError, KeyboardInterrupt):
        print('\n操作已结束。')
    except Exception as error:
        status = 1
        print(f'\n未能完成：{error}')
    try:
        input('\n回车关闭')
    except (EOFError, KeyboardInterrupt):
        pass
    raise SystemExit(status)
PYTHON
"$PY" -c "$CODEX_URL_SCRIPT" "$@"
