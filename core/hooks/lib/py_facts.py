"""AST readers for check-py.py: what a module binds, which imports are
allowed to fail, whether a call fits a signature, and two index shapes
that always raise IndexError.

Standard library only. Nothing here imports or runs project code. Split
from check-py.py to keep both files inside the 400-line budget.
"""
import ast

DEFS = (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)
FUNCS = (ast.FunctionDef, ast.AsyncFunctionDef)
SOFT_TESTS = ("version_info", "platform", "TYPE_CHECKING", "implementation")


def module_names(tree):
    """Names bound at module level, or None when the module builds them at runtime."""
    names = set()
    stack = [tree]
    while stack:
        cur = stack.pop()
        for child in ast.iter_child_nodes(cur):
            if isinstance(child, DEFS):
                if child.name == "__getattr__":
                    return None
                names.add(child.name)
                continue
            if isinstance(child, ast.Lambda):
                continue
            if isinstance(child, ast.Import):
                for a in child.names:
                    names.add(a.asname or a.name.split(".")[0])
            elif isinstance(child, ast.ImportFrom):
                for a in child.names:
                    if a.name == "*":
                        return None
                    names.add(a.asname or a.name)
            elif isinstance(child, ast.Name) and isinstance(child.ctx, ast.Store):
                names.add(child.id)
            elif isinstance(child, ast.Call) and isinstance(child.func, ast.Name) and child.func.id in ("globals", "vars", "setattr", "exec"):
                return None
            stack.append(child)
    # A function that declares `global X` and assigns it binds a module name too.
    for node in ast.walk(tree):
        if isinstance(node, ast.Global):
            names.update(node.names)
    return names


def binding_counts(tree):
    """How many times each name is bound anywhere in the file."""
    counts = {}

    def bump(name):
        counts[name] = counts.get(name, 0) + 1

    for node in ast.walk(tree):
        if isinstance(node, DEFS):
            bump(node.name)
        elif isinstance(node, ast.arg):
            bump(node.arg)
        elif isinstance(node, ast.Name) and isinstance(node.ctx, (ast.Store, ast.Del)):
            bump(node.id)
        elif isinstance(node, (ast.Import, ast.ImportFrom)):
            for a in node.names:
                bump(a.asname or a.name.split(".")[0])
        elif isinstance(node, ast.ExceptHandler) and node.name:
            bump(node.name)
    return counts


def plain_functions(tree):
    """Module-level functions with one definition, no decorator, never rebound."""
    counts = binding_counts(tree)
    out = {}
    for node in tree.body:
        if isinstance(node, FUNCS) and not node.decorator_list and counts.get(node.name) == 1:
            out[node.name] = node
    return out


def catches_import_error(handlers):
    for h in handlers:
        if h.type is None:
            return True
        for sub in ast.walk(h.type):
            if isinstance(sub, ast.Name) and sub.id in ("ImportError", "ModuleNotFoundError", "Exception", "BaseException"):
                return True
    return False


def collect_imports(tree):
    """(node, optional) for every import. Optional ones are allowed to fail."""
    out = []

    def visit(node, optional):
        for child in ast.iter_child_nodes(node):
            if isinstance(child, (ast.Import, ast.ImportFrom)):
                out.append((child, optional))
            elif isinstance(child, ast.Try):
                guarded = optional or catches_import_error(child.handlers)
                for stmt in child.body:
                    if isinstance(stmt, (ast.Import, ast.ImportFrom)):
                        out.append((stmt, guarded))
                    else:
                        visit(stmt, guarded)
                for part in list(child.handlers) + list(child.orelse) + list(child.finalbody):
                    if isinstance(part, (ast.Import, ast.ImportFrom)):
                        out.append((part, True))
                    else:
                        visit(part, True)
            elif isinstance(child, ast.If) and any(word in ast.dump(child.test) for word in SOFT_TESTS):
                for stmt in list(child.body) + list(child.orelse):
                    if isinstance(stmt, (ast.Import, ast.ImportFrom)):
                        out.append((stmt, True))
                    else:
                        visit(stmt, True)
            else:
                visit(child, optional)

    visit(tree, False)
    return out


def signature_problem(fn, call):
    """Why this call can't bind to `fn`, or None."""
    a = fn.args
    if any(isinstance(x, ast.Starred) for x in call.args) or any(k.arg is None for k in call.keywords):
        return None
    posonly = [p.arg for p in getattr(a, "posonlyargs", [])]
    regular = [p.arg for p in a.args]
    positional = posonly + regular
    kwonly = [p.arg for p in a.kwonlyargs]
    given = len(call.args)
    if a.vararg is None and given > len(positional):
        plural = "" if len(positional) == 1 else "s"
        return "takes %d positional argument%s and this call passes %d" % (len(positional), plural, given)
    filled = set(positional[:given])
    for k in call.keywords:
        if k.arg in filled:
            return "gets '%s' twice, by position and by name" % k.arg
        if k.arg in regular or k.arg in kwonly:
            filled.add(k.arg)
        elif a.kwarg is None:
            return "has no parameter named '%s'" % k.arg
    required = positional[: len(positional) - len(a.defaults)]
    required += [name for name, default in zip(kwonly, a.kw_defaults) if default is None]
    missing = [name for name in required if name not in filled]
    if missing:
        plural = "" if len(missing) == 1 else "s"
        return "is missing the required argument%s %s" % (plural, ", ".join("'%s'" % m for m in missing))
    return None


def bound_findings(tree):
    out = []

    def index_of(sub):
        s = sub.slice
        return s.value if type(s).__name__ == "Index" else s

    def len_arg(node):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "len" and len(node.args) == 1 and not node.keywords:
            return ast.dump(node.args[0])
        return None

    for node in ast.walk(tree):
        if isinstance(node, ast.Subscript) and isinstance(node.ctx, ast.Load) and isinstance(node.value, (ast.Name, ast.Attribute)):
            if len_arg(index_of(node)) == ast.dump(node.value):
                out.append((node.lineno, "indexing a sequence at len() of itself is always out of range. The last item is at -1."))
        elif isinstance(node, ast.For) and isinstance(node.target, ast.Name) and isinstance(node.iter, ast.Call):
            it = node.iter
            if not (isinstance(it.func, ast.Name) and it.func.id == "range" and 1 <= len(it.args) <= 2 and not it.keywords):
                continue
            if len(it.args) == 2 and not (isinstance(it.args[0], ast.Constant) and it.args[0].value == 0):
                continue
            stop = it.args[-1]
            if not (isinstance(stop, ast.BinOp) and isinstance(stop.op, ast.Add) and isinstance(stop.right, ast.Constant) and stop.right.value == 1):
                continue
            seq = len_arg(stop.left)
            if seq is None:
                continue
            for sub in ast.walk(node):
                if not (isinstance(sub, ast.Subscript) and isinstance(sub.ctx, ast.Load) and ast.dump(sub.value) == seq):
                    continue
                idx = index_of(sub)
                if isinstance(idx, ast.Name) and idx.id == node.target.id:
                    out.append((node.lineno, "range(len(x) + 1) runs one pass too many, and indexing with '%s' raises IndexError on the last one. Use range(len(x))." % idx.id))
                    break
    return out
