#!/usr/bin/env python3
"""
Testes estaticos do projeto (nao precisam do servidor rodando).

Checagens:
  plugins   - todo `sm plugins load` aponta para um .smx existente (tools/check_plugins.sh)
  exec      - todo `exec` aponta para um cfg existente
  modes     - cada modo confogl: arquivos obrigatorios + confogl_addcvar duplicado (so o 1o vale)
  overlap   - cvar definido no server.cfg (+ tickrate) E tambem no modo (um sobrescreve o outro)
  ranges    - valor de cvar fora do minimo/maximo declarado no plugin
  stripper  - sintaxe dos cfgs do stripper (chaves, secoes, linhas "chave" "valor")
  compile   - os plugins carregados pelos nossos modos compilam; .smx mais antigo que o .sp

Problemas nos arquivos NOSSOS sao FAIL (exit 1). Nos arquivos herdados do upstream
(outros modos, stripper de outros configs) sao WARN e nao quebram o teste.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CFG = os.path.join(ROOT, "cfg")
SM = os.path.join(ROOT, "addons", "sourcemod")
SCRIPTING = os.path.join(SM, "scripting")
PLUGINS = os.path.join(SM, "plugins")

# ---------------------------------------------------------------- configuracao
# Modos confogl que sao nossos (os demais vem do upstream).
OUR_MODE_PREFIXES = ("vanillaplus", "t1kits")
# Arquivos de cfg nossos, fora dos modos (relativos a cfg/).
OUR_CFG_FILES = ("server.cfg", "generalfixes.cfg", "sharedplugins.cfg", "zonamod/", "sourcemod/lilac_config.cfg")
# Pastas de stripper nossas (relativas a raiz).
OUR_STRIPPER_DIRS = ("addons/stripper/maps", "cfg/stripper/zonamod")
# Cfgs que existem so no servidor (gerados pelo jogo), nao no repositorio.
EXEC_ALLOW_MISSING = {"banned_user.cfg", "banned_ip.cfg"}
# Cvars que podem estar no server.cfg E no modo de proposito.
OVERLAP_ALLOWED = {
    "mp_gamemode": "server.cfg garante versus no boot; o confogl garante durante o match",
}
# Cfgs executados pelo confogl ao carregar um modo (confogl_match_execcfg_plugins/on/off).
MODE_PLUGIN_CFGS = ("generalfixes.cfg", "confogl_plugins.cfg", "sharedplugins.cfg")
# Plugins sempre compilados (alem dos carregados pelos nossos modos).
ALWAYS_COMPILE = ("confoglcompmod.sp", "diag_director.sp")
# Comandos que aparecem nos cfgs e nao sao cvars.
COMMANDS = {
    "exec", "sm", "sm_cvar", "log", "writeip", "writeid", "echo", "alias", "say", "map", "changelevel",
    "sm_forcematch", "sm_fm", "sm_resetmatch", "confogl_addcvar", "confogl_setcvars", "confogl_resetcvars",
    "confogl_resetclientcvars", "confogl_trackclientcvar", "pm_unload_plugins", "sm_resetstringcount",
    "reset_static_maps", "sm_addcvar", "banid", "addip",
    "static_tank_map", "static_witch_map", "l4d_wlimits_add", "l4d_wlimits_lock", "l4d_wlimits_clear",
}

# ---------------------------------------------------------------- saida
results = defaultdict(list)  # check -> [(level, msg)]


def report(check, level, msg):
    results[check].append((level, msg))


def rel(path):
    return os.path.relpath(path, ROOT)


def is_ours_cfg(path):
    r = os.path.relpath(path, CFG).replace(os.sep, "/")
    if r.startswith("cfgogl/"):
        mode = r.split("/")[1]
        return mode.startswith(OUR_MODE_PREFIXES)
    return any(r == f or (f.endswith("/") and r.startswith(f)) for f in OUR_CFG_FILES)


def level_for(path):
    return "FAIL" if is_ours_cfg(path) else "WARN"


# ---------------------------------------------------------------- parsing de cfg
def strip_comment(line):
    out, quoted, i = [], False, 0
    while i < len(line):
        c = line[i]
        if c == '"':
            quoted = not quoted
        elif not quoted and line.startswith("//", i):
            break
        out.append(c)
        i += 1
    return "".join(out).strip()


def tokens(line):
    return [t[1:-1] if t.startswith('"') and t.endswith('"') and len(t) > 1 else t
            for t in re.findall(r'"[^"]*"|\S+', line)]


def read_lines(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        for n, raw in enumerate(f, 1):
            line = strip_comment(raw.rstrip("\r\n"))
            if line:
                yield n, line


def resolve_exec(name, base_dir=None):
    """Caminho de um `exec name`. Tenta base_dir (pasta do modo) e depois cfg/."""
    cands = [name] if name.endswith(".cfg") else [name + ".cfg", name]
    for d in ([base_dir] if base_dir else []) + [CFG]:
        for c in cands:
            p = os.path.join(d, c)
            if os.path.isfile(p):
                return p
    return None


def expand(path, stack=()):
    """Expande `exec` recursivamente. Gera (arquivo, linha, tokens)."""
    for n, line in read_lines(path):
        t = tokens(line)
        if t[0] == "exec" and len(t) >= 2:
            if t[1] in EXEC_ALLOW_MISSING:
                continue  # listas de ban, nao sao configuracao
            target = resolve_exec(t[1])
            if target is None or target in stack:
                continue  # exec ausente e reportado pela checagem `exec`
            yield from expand(target, stack + (path,))
            continue
        yield path, n, t


def cvar_of(t):
    """(nome, valor, kind) se a linha define um cvar, senao None."""
    if t[0] == "confogl_addcvar" and len(t) >= 3:
        return t[1].lower(), t[2], "addcvar"
    if t[0] == "sm_cvar" and len(t) >= 3:
        return t[1].lower(), t[2], "sm_cvar"
    if t[0].lower() not in COMMANDS and len(t) >= 2 and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", t[0]):
        return t[0].lower(), t[1], "plain"
    return None


def all_cfg_files():
    for d, _, files in os.walk(CFG):
        for f in files:
            if f.endswith(".cfg"):
                yield os.path.join(d, f)


def modes():
    base = os.path.join(CFG, "cfgogl")
    for m in sorted(os.listdir(base)):
        if os.path.isfile(os.path.join(base, m, "confogl.cfg")):
            yield m


# ---------------------------------------------------------------- checagens
def check_plugins():
    script = os.path.join(ROOT, "tools", "check_plugins.sh")
    p = subprocess.run(["bash", script], capture_output=True, text=True)
    for line in p.stdout.splitlines():
        if line.startswith("MISSING"):
            report("plugins", "FAIL", line)
    if p.returncode == 0:
        report("plugins", "OK", p.stdout.strip().splitlines()[-1])


def check_exec():
    total = 0
    for path in all_cfg_files():
        mode_dir = os.path.dirname(path) if "/cfgogl/" in path.replace(os.sep, "/") else None
        for n, line in read_lines(path):
            t = tokens(line)
            if t[0] != "exec" or len(t) < 2:
                continue
            total += 1
            if t[1] in EXEC_ALLOW_MISSING:
                continue
            if resolve_exec(t[1], mode_dir) is None:
                report("exec", level_for(path), f"{rel(path)}:{n}: exec {t[1]} -> arquivo nao existe")
    report("exec", "OK", f"{total} exec(s) verificados")


def check_modes():
    for m in modes():
        d = os.path.join(CFG, "cfgogl", m)
        lvl = "FAIL" if m.startswith(OUR_MODE_PREFIXES) else "WARN"
        for f in ("confogl.cfg", "confogl_off.cfg", "confogl_plugins.cfg"):
            if not os.path.isfile(os.path.join(d, f)):
                report("modes", lvl, f"{m}: falta {f}")
        seen = {}
        for path, n, t in expand(os.path.join(d, "confogl.cfg")):
            c = cvar_of(t)
            if not c or c[2] != "addcvar":
                continue
            name, val, _ = c
            if name in seen:
                fp, fn, fv = seen[name]
                if fv != val:
                    report("modes", lvl, f"{m}: {name} = {val} ({rel(path)}:{n}) e IGNORADO; "
                                         f"vale {fv} ({rel(fp)}:{fn})")
                else:
                    report("modes", lvl, f"{m}: {name} repetido com o mesmo valor ({rel(path)}:{n} e {rel(fp)}:{fn})")
            else:
                seen[name] = (path, n, val)
    report("modes", "OK", f"{sum(1 for _ in modes())} modos verificados")


def server_cvars():
    out = defaultdict(list)
    for path, n, t in expand(os.path.join(CFG, "server.cfg")):
        c = cvar_of(t)
        if c:
            out[c[0]].append((path, n, c[1]))
    return out


def check_overlap():
    srv = server_cvars()
    for name, defs in sorted(srv.items()):
        if len(defs) > 1:
            where = ", ".join(f"{rel(p)}:{n}={v}" for p, n, v in defs)
            report("overlap", "FAIL", f"{name} definido {len(defs)}x no server.cfg/tickrate: {where}")
    for m in modes():
        if not m.startswith(OUR_MODE_PREFIXES):
            continue
        for path, n, t in expand(os.path.join(CFG, "cfgogl", m, "confogl.cfg")):
            c = cvar_of(t)
            if not c or c[0] not in srv or c[0] in OVERLAP_ALLOWED:
                continue
            sp, sn, sv = srv[c[0]][0]
            report("overlap", "FAIL", f"{m}: {c[0]} = {c[1]} ({rel(path)}:{n}) tambem esta em {rel(sp)}:{sn} = {sv}")
    report("overlap", "OK", f"{len(srv)} cvars do server.cfg comparados com os modos "
                            f"(permitidos: {', '.join(OVERLAP_ALLOWED)})")


def split_args(s):
    args, depth, cur, quoted, i = [], 0, [], False, 0
    while i < len(s):
        c = s[i]
        if c == "\\" and quoted:
            cur.append(s[i:i + 2]); i += 2; continue
        if c == '"':
            quoted = not quoted
        elif not quoted:
            if c in "([{":
                depth += 1
            elif c in ")]}":
                if depth == 0:
                    args.append("".join(cur).strip())
                    return args
                depth -= 1
            elif c == "," and depth == 0:
                args.append("".join(cur).strip()); cur = []; i += 1; continue
        cur.append(c)
        i += 1
    return None


def num(s):
    try:
        return float(s.rstrip("f"))
    except (ValueError, AttributeError):
        return None


def plugin_ranges():
    """nome do cvar -> (min, max) a partir de CreateConVar/CreateConVarEx nos .sp."""
    ranges, conflict = {}, set()
    for d, _, files in os.walk(SCRIPTING):
        if "/archive" in d.replace(os.sep, "/"):
            continue
        for f in files:
            if not f.endswith((".sp", ".inc")):
                continue
            src = open(os.path.join(d, f), encoding="utf-8", errors="replace").read()
            for m in re.finditer(r"\b(CreateConVar|CreateConVarEx|AutoExecConfig_CreateConVar)\s*\(", src):
                a = split_args(src[m.end():m.end() + 2000])
                if not a or len(a) < 6 or not re.fullmatch(r'"[^"]+"', a[0]):
                    continue
                name = a[0][1:-1].lower()
                if m.group(1) == "CreateConVarEx":
                    name = "confogl_" + name
                lo = num(a[5]) if a[4] == "true" else None
                hi = num(a[7]) if len(a) >= 8 and a[6] == "true" else None
                if lo is None and hi is None:
                    continue
                if name in ranges and ranges[name] != (lo, hi):
                    conflict.add(name)
                ranges[name] = (lo, hi)
    for n in conflict:
        ranges.pop(n, None)
    return ranges


def autoexec_ranges(path):
    """lilac_config.cfg e similares: comentarios // Minimum: "x" / // Maximum: "y" antes do cvar."""
    out, lo, hi = {}, None, None
    with open(path, encoding="utf-8", errors="replace") as f:
        for raw in f:
            s = raw.strip()
            m = re.match(r'//\s*Minimum:\s*"([^"]+)"', s)
            if m:
                lo = num(m.group(1)); continue
            m = re.match(r'//\s*Maximum:\s*"([^"]+)"', s)
            if m:
                hi = num(m.group(1)); continue
            line = strip_comment(s)
            if line:
                t = tokens(line)
                if len(t) >= 2 and (lo is not None or hi is not None):
                    out[t[0].lower()] = (lo, hi)
                lo = hi = None
    return out


def check_ranges():
    ranges = plugin_ranges()
    sm_dir = os.path.join(CFG, "sourcemod")
    for f in sorted(os.listdir(sm_dir)):
        if f.endswith(".cfg"):
            ranges.update(autoexec_ranges(os.path.join(sm_dir, f)))

    targets = [os.path.join(CFG, "server.cfg")]
    targets += [os.path.join(CFG, "cfgogl", m, "confogl.cfg") for m in modes() if m.startswith(OUR_MODE_PREFIXES)]
    targets += [os.path.join(sm_dir, f) for f in sorted(os.listdir(sm_dir)) if f.endswith(".cfg")]
    checked, seen = 0, set()
    for target in targets:
        for path, n, t in expand(target):
            c = cvar_of(t)
            if not c or c[0] not in ranges or (path, n) in seen:
                continue
            seen.add((path, n))
            v = num(c[1])
            if v is None:
                continue
            checked += 1
            lo, hi = ranges[c[0]]
            if (lo is not None and v < lo) or (hi is not None and v > hi):
                report("ranges", level_for(path),
                       f"{rel(path)}:{n}: {c[0]} = {c[1]} fora do intervalo [{lo if lo is not None else '-'}, "
                       f"{hi if hi is not None else '-'}] (o jogo vai limitar o valor)")
    report("ranges", "OK", f"{checked} valores verificados contra {len(ranges)} limites conhecidos")


STRIPPER_TOKEN = re.compile(r'"[^"]*"|[{}]|[A-Za-z]+:|;.*|//.*|#.*|\S+')


def check_stripper_file(path, lvl):
    """Valida a estrutura de um cfg do Stripper:Source.
    Sem cabecalho, o stripper comeca em modo filter. Em modify:, cada bloco tem
    sub-blocos match:/replace:/delete:/insert:."""
    section, depth, sub, errors = "filter:", 0, None, []
    block_start, block_has_sub = 0, False
    with open(path, encoding="utf-8", errors="replace") as f:
        for n, raw in enumerate(f, 1):
            toks = [t for t in STRIPPER_TOKEN.findall(raw) if not t.startswith((";", "//", "#"))]
            i = 0
            while i < len(toks):
                t, low = toks[i], toks[i].lower()
                if low in ("filter:", "remove:", "add:", "modify:"):
                    if depth != 0:
                        errors.append(f"{n}: '{t}' dentro de um bloco aberto (falta '}}'?)")
                    section, sub = ("filter:" if low == "remove:" else low), None
                elif low in ("match:", "replace:", "delete:", "insert:"):
                    if section != "modify:" or depth != 1:
                        errors.append(f"{n}: '{t}' so vale dentro de um bloco modify:")
                    sub, block_has_sub = low, True
                elif t == "{":
                    depth += 1
                    if depth == 1:
                        block_start, block_has_sub = n, False
                    if depth == 2 and (section != "modify:" or sub is None):
                        errors.append(f"{n}: '{{' aninhado sem match:/replace:/delete:/insert: antes")
                    if depth > 2:
                        errors.append(f"{n}: '{{' aninhado demais")
                elif t == "}":
                    depth -= 1
                    if depth < 0:
                        errors.append(f"{n}: '}}' sem '{{' correspondente")
                        depth = 0
                    if depth == 0:
                        if section == "modify:" and not block_has_sub:
                            errors.append(f"{block_start}: bloco em modify: sem match:/replace:/... "
                                          f"(faltou um 'add:' ou 'filter:' antes dele?)")
                        sub = None
                elif t.startswith('"'):
                    if i + 1 >= len(toks) or not toks[i + 1].startswith('"'):
                        errors.append(f"{n}: chave sem valor: {t}")
                    else:
                        i += 1
                        need = 2 if section == "modify:" else 1
                        if depth != need and not (section == "modify:" and depth == 1):
                            errors.append(f"{n}: chave/valor fora de um bloco: {t} {toks[i]}")
                else:
                    errors.append(f"{n}: token nao reconhecido: {t[:60]}")
                i += 1
    if depth != 0:
        errors.append(f"fim do arquivo com {depth} bloco(s) aberto(s)")
    for e in errors:
        report("stripper", lvl, f"{rel(path)}:{e}")
    return len(errors)


def check_stripper():
    files = 0
    for base in (os.path.join(ROOT, "addons", "stripper"), os.path.join(CFG, "stripper")):
        for d, _, fs in os.walk(base):
            for f in fs:
                if not f.endswith(".cfg"):
                    continue
                p = os.path.join(d, f)
                r = rel(p).replace(os.sep, "/")
                ours = any(r.startswith(x + "/") for x in OUR_STRIPPER_DIRS)
                check_stripper_file(p, "FAIL" if ours else "WARN")
                files += 1
    report("stripper", "OK", f"{files} arquivos verificados")


def find_compiler():
    src = os.path.join(SCRIPTING, "sourcemod", "spcomp64")
    if not os.path.isfile(src):
        return None, None
    tmp = tempfile.mkdtemp(prefix="test_static_")
    exe = os.path.join(tmp, "spcomp64")
    shutil.copy(src, exe)  # o binario do repo pode estar sem +x
    os.chmod(exe, 0o755)
    return exe, tmp


def loaded_by_our_modes():
    """Caminhos de .smx (relativos a plugins/) carregados pelos nossos modos."""
    out = set()
    roots = [os.path.join(CFG, f) for f in ("generalfixes.cfg", "sharedplugins.cfg")]
    for m in modes():
        if m.startswith(OUR_MODE_PREFIXES):
            roots.append(os.path.join(CFG, "cfgogl", m, "confogl_plugins.cfg"))
    for r in roots:
        if not os.path.isfile(r):
            continue
        for _, _, t in expand(r):
            if t[:3] == ["sm", "plugins", "load"] and len(t) >= 4:
                out.add(t[3] if t[3].endswith(".smx") else t[3] + ".smx")
    return out


def check_compile():
    exe, tmp = find_compiler()
    if not exe:
        report("compile", "WARN", "spcomp64 nao encontrado em addons/sourcemod/scripting/sourcemod/")
        return
    sources = {}
    for d, dirs, files in os.walk(SCRIPTING):
        dirs[:] = [x for x in dirs if x not in ("archive", "include", "sourcemod")]
        for f in files:
            if f.endswith(".sp"):
                sources.setdefault(f[:-3], os.path.join(d, f))
    wanted = {}
    for smx in loaded_by_our_modes():
        name = os.path.basename(smx)[:-4]
        if name in sources:
            wanted[sources[name]] = os.path.join(PLUGINS, smx)
    for f in ALWAYS_COMPILE:
        p = os.path.join(SCRIPTING, f)
        smx = next((os.path.join(d, f[:-3] + ".smx") for d, _, fs in os.walk(PLUGINS) if f[:-3] + ".smx" in fs), None)
        wanted.setdefault(p, smx)

    ok = 0
    try:
        for sp, smx in sorted(wanted.items()):
            out = os.path.join(tmp, "out.smx")
            p = subprocess.run([exe, sp, "-i", os.path.join(SCRIPTING, "include"),
                                "-i", os.path.join(SCRIPTING, "sourcemod", "include"), "-o", out],
                               cwd=os.path.dirname(sp), capture_output=True, text=True)
            errs = [l.strip().replace(os.path.dirname(sp) + os.sep, "")
                    for l in p.stdout.splitlines() if ": error " in l or ": fatal error " in l]
            if p.returncode != 0:
                missing_inc = all("error 417" in e for e in errs) and errs
                lvl = "WARN" if missing_inc else "FAIL"
                why = "include ausente no repositorio" if missing_inc else "erro de compilacao"
                report("compile", lvl, f"{rel(sp)}: {why}: {errs[0] if errs else p.stdout.strip()[-200:]}")
                continue
            ok += 1
            if smx and os.path.isfile(smx) and os.path.getmtime(sp) > os.path.getmtime(smx) + 1:
                report("compile", "WARN", f"{rel(sp)} e mais novo que {rel(smx)} (recompilar?)")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    report("compile", "OK", f"{ok}/{len(wanted)} plugins compilaram")


CHECKS = {
    "plugins": check_plugins,
    "exec": check_exec,
    "modes": check_modes,
    "overlap": check_overlap,
    "ranges": check_ranges,
    "stripper": check_stripper,
    "compile": check_compile,
}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("checks", nargs="*", choices=[[]] + list(CHECKS), help="checagens a rodar (padrao: todas)")
    ap.add_argument("-v", "--verbose", action="store_true", help="lista tambem os WARN do upstream")
    ap.add_argument("--no-compile", action="store_true", help="pula a compilacao (mais rapido)")
    a = ap.parse_args()
    run = a.checks or [c for c in CHECKS if not (c == "compile" and a.no_compile)]

    fails = warns = 0
    for name in run:
        CHECKS[name]()
        items = results[name]
        f = [m for l, m in items if l == "FAIL"]
        w = [m for l, m in items if l == "WARN"]
        okm = [m for l, m in items if l == "OK"]
        fails += len(f)
        warns += len(w)
        status = "FAIL" if f else ("WARN" if w else "OK")
        print(f"[{status:4}] {name}: {okm[-1] if okm else ''}"
              + (f"  ({len(f)} fail, {len(w)} warn)" if f or w else ""))
        for m in f:
            print(f"    FAIL {m}")
        if a.verbose:
            for m in w:
                print(f"    warn {m}")
        elif w:
            print(f"    {len(w)} aviso(s); rode com -v para ver")
    print(f"\nResultado: {fails} FAIL, {warns} WARN")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
