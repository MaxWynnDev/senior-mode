#!/usr/bin/env python3
"""Post-edit checks for Python files. Standard library only.

    python check-py.py <repo-root> <file>...

For each file it reports
  - a syntax error
  - an import that names nothing: no module in the repo, none in the
    standard library, none installed, none in the lockfile
  - a name imported from a module of this repo that the module doesn't define
  - a call to a plain function of this repo whose arguments can't bind
  - two index shapes that always raise IndexError

It parses with `ast` and never imports project code. An import that is
allowed to fail is left alone: one inside a `try` that catches
ImportError, or under an `if` on the Python version, the platform or
TYPE_CHECKING. Anything else it can't decide is left alone too.

One finding per line on stdout: `<path>:<line>: <message>`. Exit 1 with
findings, 0 without. If the checker itself fails it prints nothing and
exits 0, so a broken check never blocks an edit that already happened.

SM_PY_PROJECT_ENV=1 says the interpreter running this is the project's
own virtualenv, which makes "not installed here" a fact about the project.
"""
import ast
import importlib.util
import os
import re
import sys

from py_facts import binding_counts, bound_findings, collect_imports, module_names, plain_functions, signature_problem

MAX_FINDINGS = 30
EXT_SUFFIXES = (".so", ".pyd")
# Import name -> distribution name, where the two differ.
DIST_ALIASES = {
    "yaml": "pyyaml", "PIL": "pillow", "cv2": "opencv-python", "sklearn": "scikit-learn",
    "bs4": "beautifulsoup4", "dotenv": "python-dotenv", "dateutil": "python-dateutil",
    "jwt": "pyjwt", "jose": "python-jose", "multipart": "python-multipart",
    "attr": "attrs", "OpenSSL": "pyopenssl", "serial": "pyserial", "magic": "python-magic",
    "git": "gitpython", "Crypto": "pycryptodome", "zmq": "pyzmq", "docx": "python-docx",
    "pptx": "python-pptx", "fitz": "pymupdf", "MySQLdb": "mysqlclient", "psycopg2": "psycopg2-binary",
    "google": "google-", "skimage": "scikit-image", "slugify": "python-slugify",
}
LOCKS = ("uv.lock", "poetry.lock", "Pipfile.lock", "pdm.lock", "requirements.lock")


def norm(p):
    return p.replace("\\", "/")


class Repo:
    def __init__(self, root):
        # realpath: a symlinked temp dir or a Windows short name would not sit under the root
        self.root = norm(os.path.realpath(root))
        self.trees = {}
        self._lock = None
        self.project_env = os.environ.get("SM_PY_PROJECT_ENV") == "1"
        self.stdlib = getattr(sys, "stdlib_module_names", None)

    def rel(self, path):
        try:
            r = norm(os.path.relpath(path, self.root))
        except ValueError:
            return path
        return path if r.startswith("..") else r

    def tree(self, path):
        if path not in self.trees:
            try:
                with open(path, encoding="utf-8", errors="replace") as fh:
                    self.trees[path] = ast.parse(fh.read(), filename=path)
            except (OSError, SyntaxError, ValueError):
                self.trees[path] = None
        return self.trees[path]

    def lock_text(self):
        """Lowercased text of the lockfiles and requirements files, or ''."""
        if self._lock is None:
            names = list(LOCKS)
            try:
                names += [n for n in os.listdir(self.root) if n.startswith("requirements") and n.endswith(".txt")]
            except OSError:
                pass
            parts = []
            for name in names:
                try:
                    with open(os.path.join(self.root, name), encoding="utf-8", errors="replace") as fh:
                        parts.append(fh.read().lower())
                except OSError:
                    continue
            self._lock = "\n".join(parts)
        return self._lock

    def search_roots(self, file):
        roots = [self.root, self.root + "/src"]
        d = norm(os.path.dirname(file))
        while d.startswith(self.root) and d not in roots:
            roots.append(d)
            d = norm(os.path.dirname(d))
        return roots


def is_package_dir(path):
    """A folder Python would import: it has __init__.py or at least one .py file."""
    try:
        entries = os.listdir(path)
    except OSError:
        return False
    return any(e == "__init__.py" or e.endswith((".py", ".pyi")) for e in entries)


def module_at(base, name):
    """(kind, path, source file) for module `name` inside folder `base`, or None."""
    stem = base + "/" + name
    for ext in (".py", ".pyi"):
        if os.path.isfile(stem + ext):
            return ("mod", stem + ext, stem + ext)
    if os.path.isdir(stem) and is_package_dir(stem):
        init = stem + "/__init__.py"
        return ("pkg", stem, init if os.path.isfile(init) else None)
    try:
        for entry in os.listdir(base):
            if entry.startswith(name + ".") and entry.endswith(EXT_SUFFIXES):
                return ("ext", base + "/" + entry, None)
    except OSError:
        pass
    return None


def walk_module(base, parts):
    """Follow a.b.c down from folder `base`.

    Returns (found, source file, package folder, first dotted name that is missing).
    """
    cur = base
    src = None
    pkg_dir = None
    for i, part in enumerate(parts):
        hit = module_at(cur, part)
        if not hit:
            return (False, None, None, ".".join(parts[: i + 1]))
        kind, path, src = hit
        if kind == "pkg":
            cur = path
            pkg_dir = path
            continue
        pkg_dir = None
        if i != len(parts) - 1:
            return (False, None, None, ".".join(parts[: i + 2]))
    return (True, src, pkg_dir, None)


def third_party(repo, top):
    """Is `top` a real top-level module? True, False, or None when this run can't say."""
    if repo.stdlib is not None and top in repo.stdlib:
        return True
    if top in sys.builtin_module_names:
        return True
    try:
        if importlib.util.find_spec(top) is not None:
            return True
    except (ImportError, ValueError, AttributeError):
        return None
    if repo.stdlib is None:
        return None
    if repo.project_env:
        return False
    lock = repo.lock_text()
    if not lock:
        return None
    low = top.lower()
    wanted = {low, low.replace("_", "-"), "python-" + low, "py" + low}
    if top in DIST_ALIASES:
        wanted.add(DIST_ALIASES[top])
    for name in wanted:
        tail = "" if name.endswith("-") else r"($|[^a-z0-9_-])"
        if re.search(r"(^|[^a-z0-9_.-])" + re.escape(name) + tail, lock, re.M):
            return True
    return False


def resolve_import(repo, path, node, parts):
    """('ok', source file, package folder), ('skip', None, None) or ('bad', message, None)."""
    if isinstance(node, ast.ImportFrom) and node.level:
        base = norm(os.path.dirname(path))
        for _ in range(node.level - 1):
            base = norm(os.path.dirname(base))
        if not parts:
            init = base + "/__init__.py"
            return ("ok", init if os.path.isfile(init) else None, base)
        found, src, pkg_dir, missing = walk_module(base, parts)
        if found:
            return ("ok", src, pkg_dir)
        return ("bad", "cannot resolve '%s%s': no module '%s' under %s." % ("." * node.level, ".".join(parts), missing, repo.rel(base) or "."), None)
    if not parts:
        return ("skip", None, None)
    top = parts[0]
    failed = None
    for root in repo.search_roots(path):
        if not module_at(root, top):
            continue
        found, src, pkg_dir, missing = walk_module(root, parts)
        if found:
            return ("ok", src, pkg_dir)
        failed = failed or missing
    verdict = third_party(repo, top)
    if verdict is True or verdict is None:
        return ("skip", None, None)
    if failed:
        return ("bad", "cannot resolve '%s': '%s' is in this repo and it has no module '%s'." % (".".join(parts), top, failed), None)
    where = "this project's environment" if repo.project_env else "the lockfile"
    return ("bad", "cannot resolve '%s': not in this repo, not in the standard library, and not in %s." % (top, where), None)


def check_file(repo, path, findings):
    here = repo.rel(path)

    def add(line, msg):
        if len(findings) < MAX_FINDINGS:
            findings.append("%s:%s: %s" % (here, line, msg))

    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            source = fh.read()
    except OSError:
        return
    try:
        tree = ast.parse(source, filename=path)
    except SyntaxError as exc:
        add(exc.lineno or 1, "syntax error (parsed by Python %d.%d): %s" % (sys.version_info[0], sys.version_info[1], exc.msg))
        return
    except ValueError:
        return

    counts = binding_counts(tree)
    callable_here = {}
    for node, optional in collect_imports(tree):
        if optional:
            continue
        if isinstance(node, ast.Import):
            for a in node.names:
                status, detail, _ = resolve_import(repo, path, node, a.name.split("."))
                if status == "bad":
                    add(node.lineno, detail)
            continue
        status, src, pkg_dir = resolve_import(repo, path, node, node.module.split(".") if node.module else [])
        if status == "bad":
            add(node.lineno, src)
            continue
        if status != "ok":
            continue
        target = repo.tree(src) if src else None
        defined = module_names(target) if target is not None else None
        fns = plain_functions(target) if target is not None else {}
        for a in node.names:
            if a.name == "*" or (pkg_dir and module_at(pkg_dir, a.name)):
                continue
            local = a.asname or a.name
            if defined is not None and a.name not in defined:
                add(node.lineno, "'%s' has no name '%s'." % (repo.rel(src), a.name))
            elif a.name in fns and counts.get(local) == 1:
                callable_here[local] = (fns[a.name], repo.rel(src))

    for name, fn in plain_functions(tree).items():
        callable_here.setdefault(name, (fn, here))
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in callable_here:
            fn, where = callable_here[node.func.id]
            problem = signature_problem(fn, node)
            if problem:
                add(node.lineno, "%s() %s (defined at %s:%s)." % (node.func.id, problem, where, fn.lineno))
    for line, msg in bound_findings(tree):
        add(line, msg)


def main(argv):
    if len(argv) < 3:
        return 0
    repo = Repo(argv[1])
    findings = []
    for arg in argv[2:]:
        path = norm(os.path.realpath(arg))
        if path.endswith((".py", ".pyi")) and os.path.isfile(path):
            check_file(repo, path, findings)
    if findings:
        sys.stdout.write("\n".join(findings) + "\n")
    return 1 if findings else 0


if __name__ == "__main__":
    try:
        code = main(sys.argv)
    except Exception:  # the checker failing is never the edit's problem
        code = 0
    sys.exit(code)
