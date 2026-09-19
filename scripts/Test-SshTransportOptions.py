#!/usr/bin/env python3
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#8129 — Gate: every ssh/scp call in the installer goes through Invoke-CloudGrangeSsh
# (scripts/CloudGrange-Common.ps1), so it runs with -o BatchMode=yes -o ConnectTimeout=15
# -o ServerAliveInterval=15 -o ServerAliveCountMax=4 and an overall -TimeoutSeconds limit.
# Fails when:
#   - a PowerShell or shell script (archive/ and test/ excluded) starts ssh or scp directly: `& ssh.exe`, `& scp`,
#     a ProcessStartInfo or FileName of ssh/scp, Start-Process / Invoke-Expression / cmd /c / bash -c with an
#     ssh/scp command, or a bare `ssh -...` / `scp -...` command line;
#   - Get-CloudGrangeSshRequiredOptions no longer lists all four options, or Get-CloudGrangeSshOptions,
#     Invoke-CloudGrangeSsh or Invoke-CloudGrangeBoundedProcess stop applying them or the timeout;
#   - an Invoke-CloudGrangeSsh call has no literal -TimeoutSeconds <n>, or its -ArgumentList is not built from
#     Get-CloudGrangeSshOptions.
# Usage: Test-SshTransportOptions.py <repo-root>
import os
import re
import sys

REQUIRED = ["BatchMode=yes", "ConnectTimeout=15", "ServerAliveInterval=15", "ServerAliveCountMax=4"]
HELPER = "scripts/CloudGrange-Common.ps1"
EXCLUDED_DIRS = {".git", "archive", "test", "node_modules", "bin", "obj"}
EXTENSIONS = (".ps1", ".psm1", ".sh")
TOOL = r"(?:ssh|scp)(?:\.exe)?"
TOOL_COMMAND = TOOL + r"['\"]?\s+(?:-|['\"]?[^\s'\"]+@)"
PATH_PREFIX = r"(?:[^\s'\"&|;()]*[\\/])?"
DIRECT = [
    ("call operator", re.compile(r"&\s*['\"]?" + PATH_PREFIX + TOOL + r"['\"]?(?=[\s)]|$)", re.I)),
    ("process FileName", re.compile(r"FileName\s*=\s*['\"]" + PATH_PREFIX + TOOL + r"['\"]", re.I)),
    ("ProcessStartInfo", re.compile(r"ProcessStartInfo\]?(?:::new)?\s*\(\s*['\"]" + PATH_PREFIX + TOOL + r"['\"]", re.I)),
    ("Process.Start", re.compile(r"Diagnostics\.Process\]::Start\(\s*['\"]" + PATH_PREFIX + TOOL, re.I)),
    ("launcher", re.compile(r"\b(?:Start-Process|saps|Invoke-Expression|iex|Start-Job|cmd(?:\.exe)?\s+/c|bash\s+-c|sh\s+-c)\b.*?\b" + TOOL_COMMAND, re.I)),
    ("launcher", re.compile(r"\b(?:Start-Process|saps)\s+(?:-FilePath\s+)?['\"]?" + PATH_PREFIX + TOOL + r"['\"]?(?=[\s)]|$)", re.I)),
    ("bare command", re.compile(r"^\s*(?:sudo\s+|exec\s+|command\s+)?" + PATH_PREFIX + TOOL_COMMAND, re.I)),
]


def function_body(text, name):
    m = re.search(r"(?mi)^function\s+" + re.escape(name) + r"\s*\{", text)
    if not m:
        return None
    depth = 0
    start = m.end() - 1
    for j in range(start, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[start:j + 1]
    return None


def code_lines(path, text):
    if path.endswith((".ps1", ".psm1")):
        text = re.sub(r"(?s)<#.*?#>", lambda m: "\n" * m.group(0).count("\n"), text)
    for number, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        yield number, line


def balanced(text, start):
    """Return the parenthesised expression starting at text[start] == '('."""
    depth = 0
    quote = None
    for j in range(start, len(text)):
        c = text[j]
        if quote:
            if c == quote:
                quote = None
            continue
        if c in "'\"":
            quote = c
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return text[start:j + 1]
    return text[start:]


def check_helper(root, bad):
    try:
        text = open(os.path.join(root, HELPER), encoding="utf-8").read()
    except OSError as e:
        bad("%s: unreadable (%s)" % (HELPER, e))
        return
    required = function_body(text, "Get-CloudGrangeSshRequiredOptions")
    options = function_body(text, "Get-CloudGrangeSshOptions")
    invoke = function_body(text, "Invoke-CloudGrangeSsh")
    bounded = function_body(text, "Invoke-CloudGrangeBoundedProcess")
    # AB#9171: -CaptureOutput runs in Invoke-CloudGrangeBoundedProcessToFile, which is the path EVERY
    # captured ssh call takes. It is checked with the same rules as the pipe path; before this it was
    # not checked at all, so the capture path could lose its timeout kill or its stdin redirection
    # without the gate noticing.
    bounded_to_file = function_body(text, "Invoke-CloudGrangeBoundedProcessToFile")
    for name, body in (("Get-CloudGrangeSshRequiredOptions", required), ("Get-CloudGrangeSshOptions", options),
                       ("Invoke-CloudGrangeSsh", invoke), ("Invoke-CloudGrangeBoundedProcess", bounded),
                       ("Invoke-CloudGrangeBoundedProcessToFile", bounded_to_file)):
        if body is None:
            bad("%s: function %s missing" % (HELPER, name))
    if required is not None:
        for option in REQUIRED:
            if "'%s'" % option not in required:
                bad("%s: Get-CloudGrangeSshRequiredOptions does not list '%s'" % (HELPER, option))
    if options is not None and "Get-CloudGrangeSshRequiredOptions" not in options:
        bad("%s: Get-CloudGrangeSshOptions does not add the required options" % HELPER)
    if invoke is not None:
        for needle, what in (("Get-CloudGrangeSshRequiredOptions", "check the required options"),
                             ("CG-SSH-ERR-001", "refuse a call without them"),
                             ("Invoke-CloudGrangeBoundedProcess", "run through the bounded process"),
                             ("-TimeoutSeconds $TimeoutSeconds", "pass its timeout on")):
            if needle not in invoke:
                bad("%s: Invoke-CloudGrangeSsh does not %s" % (HELPER, what))
        if not re.search(r"\[Parameter\(Mandatory\)\]\s*\[ValidateRange\(1,\s*\d+\)\]\s*\[int\]\$TimeoutSeconds", invoke):
            bad("%s: Invoke-CloudGrangeSsh -TimeoutSeconds must be mandatory and bounded" % HELPER)
    for function_name, body in (("Invoke-CloudGrangeBoundedProcess", bounded),
                                ("Invoke-CloudGrangeBoundedProcessToFile", bounded_to_file)):
        if body is None:
            continue
        for needle, what in (("WaitForExit($TimeoutSeconds * 1000)", "wait with the timeout"),
                             (".Kill($true)", "stop the process tree on timeout"),
                             ("CG-SSH-ERR-002", "throw on timeout"),
                             ("RedirectStandardInput = $true", "keep stdin off the console")):
            if needle not in body:
                bad("%s: %s does not %s" % (HELPER, function_name, what))


def check_calls(rel, text, bad, counts):
    joined = re.sub(r"`\r?\n\s*", " ", text)
    assigned = {}
    for m in re.finditer(r"(?m)^\s*\$(\w+)\s*=(?!=)(.*)$", joined):
        assigned.setdefault(m.group(1).lower(), []).append("Get-CloudGrangeSshOptions" in m.group(2))
    trusted = {name for name, uses in assigned.items() if uses and all(uses)}
    for number, line in code_lines(rel, joined):
        for m in re.finditer(r"\bInvoke-CloudGrangeSsh\b(?!-)", line):
            if re.match(r"\s*function\s*$", line[:m.start()]):
                continue
            rest = line[m.end():]
            where = "%s:%d" % (rel, number)
            if not re.search(r"-TimeoutSeconds\s+[1-9]\d*\b", rest):
                bad("%s: Invoke-CloudGrangeSsh without a literal -TimeoutSeconds <n>" % where)
            tool = re.search(r"-Tool\s+['\"]?(\w+)", rest)
            if tool and tool.group(1).lower() not in ("ssh", "scp"):
                bad("%s: Invoke-CloudGrangeSsh -Tool %s" % (where, tool.group(1)))
            a = re.search(r"-ArgumentList\s+", rest)
            if not a:
                bad("%s: Invoke-CloudGrangeSsh without -ArgumentList" % where)
                continue
            expr = balanced(rest, a.end()) if rest[a.end():a.end() + 1] == "(" else re.match(r"\S+", rest[a.end():]).group(0)
            variables = {v.lower() for v in re.findall(r"\$(\w+)", expr)}
            if "Get-CloudGrangeSshOptions" not in expr and not variables & trusted:
                bad("%s: Invoke-CloudGrangeSsh -ArgumentList %s is not built from Get-CloudGrangeSshOptions" % (where, expr))
            counts[rel] = counts.get(rel, 0) + 1


def main(argv):
    if len(argv) != 2:
        print("usage: Test-SshTransportOptions.py <repo-root>", file=sys.stderr)
        return 2
    root = os.path.realpath(argv[1])
    violations = []
    bad = violations.append
    check_helper(root, bad)
    counts = {}
    scanned = 0
    for directory, dirs, files in os.walk(root):
        dirs[:] = sorted(d for d in dirs if d not in EXCLUDED_DIRS)
        for name in sorted(files):
            if not name.endswith(EXTENSIONS):
                continue
            path = os.path.join(directory, name)
            rel = os.path.relpath(path, root).replace(os.sep, "/")
            try:
                text = open(path, encoding="utf-8-sig").read()
            except (OSError, UnicodeDecodeError) as e:
                bad("%s: unreadable (%s)" % (rel, e))
                continue
            scanned += 1
            for number, line in code_lines(rel, text):
                for what, pattern in DIRECT:
                    if pattern.search(line):
                        bad("%s:%d: direct ssh/scp invocation (%s); use Invoke-CloudGrangeSsh: %s" % (rel, number, what, line.strip()))
                        break
            if rel.endswith((".ps1", ".psm1")):
                check_calls(rel, text, bad, counts)
    if violations:
        for v in violations:
            print("SSH-GATE FAIL: " + v, file=sys.stderr)
        return 1
    print("ssh transport gate passed: %d scripts scanned, %d Invoke-CloudGrangeSsh calls" % (scanned, sum(counts.values())))
    for rel in sorted(counts):
        print("  %s: %d" % (rel, counts[rel]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
