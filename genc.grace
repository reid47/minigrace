import io
import sys
import ast
import util
import buildinfo
import subtype

// genc produces C code from the AST, and optionally links and
// compiles it to native code. Code that affects the way the compiler behaves
// is in the "compile" method at the bottom. Other methods principally deal
// with translating a single AST node to C, and parallel the AST and
// parser.

var tmp
var verbosity := 30
var pad1 := 1
var auto_count := 0
var constants := []
var globals := []
var output := []
var usedvars := []
var declaredvars := []
var bblock := "entry"
var linenum := 1
var modules := []
var staticmodules := []
var values := []
var outfile
var modname := "main"
var escmodname := "main"
var runmode := "build"
var buildtype := "bc"
var gracelibPath := "gracelib.o"
var inBlock := false
var paramsUsed := 1
var topLevelMethodPos := 1
var topOutput := []
var bottomOutput := output

method out(s) {
    output.push(s)
}
method outprint(s) {
    util.outprint(s)
}
method outswitchup {
    output := topOutput   
}
method outswitchdown {
    output := bottomOutput
}
method log_verbose(s) {
    util.log_verbose(s)
}
method beginblock(s) {
    bblock := "%" ++ s
    out(s ++ ":")
}
method escapeident(s) {
    var ns := ""
    for (s) do { c ->
        def o = c.ord
        if (((o >= 65) & (o <= 90))
            | ((o >= 97) & (o <= 122))
            | ((o >= 48) & (o <= 57))
            | (o == 95)) then {
            ns := ns ++ c
        } else {
            ns := ns ++ "_{o}_"
        }
    }
    ns
}
method escapestring2(s) {
    var ns := ""
    var cd := 0
    var ls := false
    for (escapestring(s)) do { c->
        if (ls & (c == "\\")) then {
            ls := false
            ns := ns ++ "\\\\"
        } elseif (c == "\\") then {
            ls := true
        } elseif (ls) then {
            ns := ns ++ "\"\"\\x" ++ c
            ls := false
            cd := 2
        } else {
            ns := ns ++ c
        }
        if (cd == 1) then {
            ns := ns ++ "\"\""
            cd := 0
        } elseif (cd > 0) then {
            cd := cd - 1
        }
    }
    ns
}
method compilearray(o) {
    var myc := auto_count
    auto_count := auto_count + 1
    var r
    out("  Object array" ++ myc ++ " = alloc_List();")
    for (o.value) do {a ->
        r := compilenode(a)
        out("  params[0] = {r};")
        out("  callmethod(array{myc}, \"push\", 1, params);")
    }
    o.register := "array" ++ myc
}
method compilemember(o) {
    // Member in value position is actually a nullary method call.
    var l := []
    var c := ast.astcall(o, l)
    var r := compilenode(c)
    o.register := r
}
method compileobjouter(selfr) {
    var myc := auto_count
    auto_count := auto_count + 1
    var nm := "outer"
    var len := length(nm) + 1
    var enm := escapestring2(nm)
    out("// OBJECT OUTER DEC " ++ enm)
    out("  adddatum2({selfr}, self, 0);")
    outprint("Object reader_{escmodname}_{enm}_{myc}"
        ++ "(Object self, int nparams, "
        ++ "Object* args, int flags) \{")
    outprint("  struct UserObject *uo = (struct UserObject*)self;")
    outprint("  return uo->data[0];")
    outprint("\}")
    out("  addmethod2({selfr}, \"outer\", &reader_{escmodname}_{enm}_{myc});")
}
method compileobjdefdec(o, selfr, pos) {
    var val := "undefined"
    if (o.value) then {
        val := compilenode(o.value)
    }
    var myc := auto_count
    auto_count := auto_count + 1
    var nm := o.name.value
    var len := length(nm) + 1
    var enm := escapestring2(nm)
    var inm := escapeident(nm)
    out("// OBJECT CONST DEC " ++ enm)
    out("  adddatum2({selfr}, {val}, {pos});")
    outprint("Object reader_{escmodname}_{inm}_{myc}"
        ++ "(Object self, int nparams, "
        ++ "Object* args, int flags) \{")
    outprint("  struct UserObject *uo = (struct UserObject *)self;")
    outprint("  return uo->data[{pos}];")
    outprint("\}")
    out("  addmethod2({selfr}, \"{enm}\", &reader_{escmodname}_{inm}_{myc});")
}
method compileobjvardec(o, selfr, pos) {
    var val := "undefined"
    if (o.value) then {
        val := compilenode(o.value)
    }
    var myc := auto_count
    auto_count := auto_count + 1
    var nm := o.name.value
    var len := length(nm) + 1
    var enm := escapestring2(nm)
    var inm := escapeident(nm)
    out("// OBJECT VAR DEC " ++ nm)
    out("  adddatum2({selfr}, {val}, {pos});")
    outprint("Object reader_{escmodname}_{inm}_{myc}"
        ++ "(Object self, int nparams, "
        ++ "Object* args, int flags) \{")
    outprint("  struct UserObject *uo = (struct UserObject *)self;")
    outprint("  return uo->data[{pos}];")
    outprint("\}")
    out("  addmethod2({selfr}, \"{enm}\", &reader_{escmodname}_{inm}_{myc});")
    var nmw := nm ++ ":="
    len := length(nmw) + 1
    nmw := escapestring2(nmw)
    outprint("Object writer_{escmodname}_{inm}_{myc}"
        ++ "(Object self, int nparams, "
        ++ "Object* args, int flags) \{")
    outprint("  struct UserObject *uo = (struct UserObject *)self;")
    outprint("  uo->data[{pos}] = args[0];")
    outprint("  return nothing;");
    outprint("\}")
    out("  addmethod2({selfr}, \"{enm}:=\", &writer_{escmodname}_{inm}_{myc});")
}
method compileclass(o) {
    var params := o.params
    var mbody := [ast.astobject(o.value, o.superclass)]
    var newmeth := ast.astmethod(ast.astidentifier("new", false), params, mbody,
        false)
    var obody := [newmeth]
    var cobj := ast.astobject(obody, false)
    var con := ast.astdefdec(o.name, cobj, false)
    o.register := compilenode(con)
}
method compileobject(o) {
    var origInBlock := inBlock
    inBlock := false
    var myc := auto_count
    auto_count := auto_count + 1
    var selfr := "obj" ++ myc
    var numFields := 1
    var numMethods := 0
    var pos := 1
    for (o.value) do { e ->
        if (e.kind == "vardec") then {
            numMethods := numMethods + 1
        }
        numMethods := numMethods + 1
        numFields := numFields + 1
    }
    if (numFields == 3) then {
        numFields := 4
    }
    if (o.superclass /= false) then {
        selfr := compilenode(o.superclass)
    } else {
        out("  Object " ++ selfr ++ " = alloc_obj2({numMethods},"
            ++ "{numFields});")
    }
    compileobjouter(selfr)
    out("  adddatum2({selfr}, self, 0);")
    for (o.value) do { e ->
        if (e.kind == "method") then {
            compilemethod(e, selfr, pos)
        }
        if (e.kind == "vardec") then {
            compileobjvardec(e, selfr, pos)
        }
        if (e.kind == "defdec") then {
            compileobjdefdec(e, selfr, pos)
        }
        pos := pos + 1
    }
    util.runOnNew {
        out("  set_type({selfr}, "
            ++ "{subtype.typeId(o.otype)});")
    } else { }
    o.register := selfr
    inBlock := origInBlock
}
method compileblock(o) {
    def origInBlock = inBlock
    inBlock := true
    var myc := auto_count
    auto_count := auto_count + 1
    var applymeth := ast.astmethod(ast.astidentifier("apply", false),
        o.params, o.body, false)
    applymeth.selfclosure := true
    var objbody := ast.astobject([applymeth], false)
    var obj := compilenode(objbody)
    var modn := "Block<{modname}:{myc}>"
    out("  setclassname({obj}, \"{modn}\");")
    o.register := obj
    inBlock := origInBlock
}
method compilefor(o) {
    var myc := auto_count
    auto_count := auto_count + 1
    var over := compilenode(o.value)
    var blk := o.body
    var obj := compilenode(blk)
    out("  params[0] = {over};")
    out("  Object iter{myc} = callmethod({over}, \"iter\", 1, params);")
    out("  while(1) \{")
    out("    Object cond{myc} = callmethod(iter{myc}, \"havemore\", 0, NULL);")
    out("    if (!istrue(cond{myc})) break;")
    out("    params[0] = callmethod(iter{myc}, \"next\", 0, NULL);")
    out("    callmethod({obj}, \"apply\", 1, params);")
    out("  \}")
    o.register := over
}
method compilemethod(o, selfobj, pos) {
    // How to deal with closures:
    // Calculate body, find difference of usedvars/declaredvars, if closure
    // then build as such. At top of method body bind var_x as usual, but
    // set to pointer from the additional closure parameter.
    var origParamsUsed := paramsUsed
    paramsUsed := 1
    var origInBlock := inBlock
    inBlock := o.selfclosure
    var oldout := output
    var oldbblock := bblock
    var oldusedvars := usedvars
    var olddeclaredvars := declaredvars
    output := []
    usedvars := []
    declaredvars := []
    var myc := auto_count
    auto_count := auto_count + 1
    var name := o.value.value
    var nm := name ++ myc
    var i := 0
    for (o.params) do { p ->
        var pn := escapeident(p.value)
        out("  Object *var_{pn} = args + {i};")
        declaredvars.push(pn)
        i := i + 1
    }
    if (o.varargs) then {
        var van := escapeident(o.vararg.value)
        out("  Object var_init_{van} = process_varargs(args, {i}, nparams);")
        out("  Object *var_{van} = alloc_var();")
        out("  *var_{van} = var_init_{van};")
        declaredvars.push(van)
    }
    var ret := "nothing"
    for (o.body) do { l ->
        if ((l.kind == "vardec") | (l.kind == "defdec")
            | (l.kind == "class")) then {
            var tnm := escapeident(l.name.value)
            declaredvars.push(tnm)
            out("  Object *var_{tnm} = alloc_var();")
            out("  *var_{tnm} = undefined;")
        }
    }
    for (o.body) do { l ->
        ret := compilenode(l)
    }
    out("  return {ret};")
    out("\}")
    var body := output
    outswitchup
    var closurevars := []
    for (usedvars) do { u ->
        var decl := false
        for (declaredvars) do { d->
            if (d == u) then {
                decl := true
            }
        }
        if (decl) then {
            decl := decl
        } else {
            var found := false
            for (closurevars) do { v ->
                if (v == u) then {
                    found := true
                }
            }
            if (found) then {
                found := found
            } else {
                closurevars.push(u)
            }
        }
    }
    if (o.selfclosure) then {
        closurevars.push("self")
    }
    var litname := escapeident("meth_{modname}_{escapestring2(nm)}")
    if (closurevars.size > 0) then {
        if (o.selfclosure) then {
            out("Object {litname}(Object realself, int nparams, "
                ++ "Object *args, int32_t flags) \{")
            out("  struct UserObject *uo = (struct UserObject*)realself;")
        } else {
            out("Object {litname}(Object self, int nparams, Object *args, "
                ++ "int32_t flags) \{")
            out("  struct UserObject *uo = (struct UserObject*)self;")
        }
        out("  Object **closure = uo->data[{pos}];")
    } else {
        out("Object {litname}(Object self, int nparams, Object *args, "
            ++ "int32_t flags) \{")
    }
    out("  Object params[{paramsUsed}];")
    var j := 0
    for (closurevars) do { cv ->
        if (cv == "self") then {
            out("  Object self = *closure[{j}];")
        } else {
            out("  Object *var_{cv} = closure[{j}];")
        }
        j := j + 1
    }
    for (body) do { l->
        out(l)
    }
    outswitchdown
    output := oldout
    bblock := oldbblock
    usedvars := oldusedvars
    declaredvars := olddeclaredvars
    for (closurevars) do { cv ->
        if (cv /= "self") then {
            if ((usedvars.contains(cv)).not) then {
                usedvars.push(cv)
            }
        }
    }
    var len := length(name) + 1
    if (closurevars.size == 0) then {
        out("  addmethod2({selfobj}, \"{escapestring2(name)}\", &{litname});")
    } else {
        out("  block_savedest({selfobj});")
        out("  Object **closure" ++ myc ++ " = createclosure("
            ++ closurevars.size ++ ");")
        for (closurevars) do { v ->
            if (v == "self") then {
                out("  Object *selfpp{auto_count} = "
                    ++ "alloc_var();")
                out("  *selfpp{auto_count} = self;")
                out("  addtoclosure(closure{myc}, selfpp{auto_count});")
                auto_count := auto_count + 1
            } else {
                out("  addtoclosure(closure{myc}, var_{v});")
            }
        }
        var uo := "uo{myc}"
        out("  struct UserObject *{uo} = (struct UserObject*){selfobj};")
        out("  {uo}->data[{pos}] = (Object)closure{myc};")
        out("  addmethod2({selfobj}, \"{escapestring2(name)}\", &{litname});")
    }
    inBlock := origInBlock
    paramsUsed := origParamsUsed
}
method compilewhile(o) {
    var myc := auto_count
    auto_count := auto_count + 1
    out("  Object while{myc};")
    out("  while (1) \{")
    def cond = compilenode(o.value)
    out("    while{myc} = {cond};")
    out("    if (!istrue({cond})) break;")
    var tret := "null"
    for (o.body) do { l ->
        if ((l.kind == "vardec") | (l.kind == "defdec")
            | (l.kind == "class")) then {
            var tnm := escapeident(l.name.value)
            declaredvars.push(tnm)
            out("  Object *var_{tnm} = alloc_var();")
            out("  *var_{tnm} = undefined;")
        }
    }
    for (o.body) do { l->
        tret := compilenode(l)
    }
    out("  \}")
    o.register := "while" ++ myc
}
method compileif(o) {
    var myc := auto_count
    auto_count := auto_count + 1
    var cond := compilenode(o.value)
    out("  Object if{myc};")
    out("  if (istrue({cond})) \{")
    var tret := "undefined"
    var fret := "undefined"
    var tblock := "ERROR"
    var fblock := "ERROR"
    for (o.thenblock) do { l ->
        if ((l.kind == "vardec") | (l.kind == "defdec")
            | (l.kind == "class")) then {
            var tnm := escapeident(l.name.value)
            declaredvars.push(tnm)
            out("  Object *var_{tnm} = alloc_var();")
            out("  *var_{tnm} = undefined;")
        }
    }
    for (o.thenblock) do { l->
        tret := compilenode(l)
    }
    out("    if{myc} = {tret};")
    out("  \} else \{")
    if (o.elseblock.size > 0) then {
        for (o.elseblock) do { l ->
            if ((l.kind == "vardec") | (l.kind == "defdec")
                | (l.kind == "class")) then {
                var tnm := escapeident(l.name.value)
                declaredvars.push(tnm)
                out("  Object *var_{tnm} = alloc_var();")
                out("  *var_{tnm} = undefined;")
            }
        }
        for (o.elseblock) do { l->
            fret := compilenode(l)
        }
        out("    if{myc} = {fret};")
    }
    out("  \}")
    o.register := "if" ++ myc
}
method compileidentifier(o) {
    var name := escapeident(o.value)
    if (name == "self") then {
        o.register := "self"
    } elseif (name == "__compilerRevision") then {
        out("  Object var_val___compilerRevision" ++ auto_count
            ++ " = alloc_String(compilerRevision);")
        o.register := "var_val___compilerRevision" ++ auto_count
        auto_count := auto_count + 1
    } else {
        name := escapestring2(name)
        if (modules.contains(name)) then {
            o.register := "module_" ++ name
        } else {
            usedvars.push(name)
            o.register := "*var_{name}"
        }
    }
}
method compilebind(o) {
    var dest := o.dest
    var val := ""
    var c := ""
    var r := ""
    if (dest.kind == "identifier") then {
        val := o.value
        val := compilenode(val)
        var nm := escapestring2(dest.value)
        usedvars.push(nm)
        out("  *var_{nm} = {val};")
        out("  if ({val} == undefined)")
        out("    callmethod(nothing, \"assignment\", 0, NULL);")
        auto_count := auto_count + 1
        o.register := val
    } elseif (dest.kind == "member") then {
        dest.value := dest.value ++ ":="
        c := ast.astcall(dest, [o.value])
        r := compilenode(c)
        o.register := r
    } elseif (dest.kind == "index") then {
        var imem := ast.astmember("[]:=", dest.value)
        c := ast.astcall(imem, [dest.index, o.value])
        r := compilenode(c)
        o.register := r
    }
    o.register := "nothing"
}
method compiledefdec(o) {
    var nm := escapeident(o.name.value)
    declaredvars.push(nm)
    var val := o.value
    if (val) then {
        val := compilenode(val)
    } else {
        util.syntax_error("const must have value bound.")
    }
    out("  *var_{nm} = {val};")
    out("  if ({val} == undefined)")
    out("    callmethod(nothing, \"assignment\", 0, NULL);")
    o.register := "nothing"
}
method compilevardec(o) {
    var nm := escapeident(o.name.value)
    declaredvars.push(nm)
    var val := o.value
    var hadval := false
    if (val) then {
        val := compilenode(val)
        hadval := true
    } else {
        val := "undefined"
    }
    out("  var_{nm} = alloc_var();")
    out("  *var_{nm} = {val};")
    if (hadval) then {
        out("  if ({val} == undefined)")
        out("    callmethod(nothing, \"assignment\", 0, NULL);")
    }
    o.register := "nothing"
}
method compileindex(o) {
    var of := compilenode(o.value)
    var index := compilenode(o.index)
    out("  params[0] = {index};")
    out("  Object idxres{auto_count} = callmethod({of}, \"[]\", 1, params);")
    o.register := "idxres" ++ auto_count
    auto_count := auto_count + 1
}
method compileop(o) {
    var left := compilenode(o.left)
    var right := compilenode(o.right)
    auto_count := auto_count + 1
    if ((o.value == "+") | (o.value == "*") | (o.value == "/") |
        (o.value == "-") | (o.value == "%")) then {
        var rnm := "sum"
        if (o.value == "*") then {
            rnm := "prod"
        }
        if (o.value == "/") then {
            rnm := "quotient"
        }
        if (o.value == "-") then {
            rnm := "diff"
        }
        if (o.value == "%") then {
            rnm := "modulus"
        }
        out("  params[0] = {right};")
        out("  Object {rnm}{auto_count} = callmethod({left}, \"{o.value}\", "
            ++ "1, params);")
        o.register := rnm ++ auto_count
        auto_count := auto_count + 1
    } else {
        var len := length(o.value) + 1
        var evl := escapestring2(o.value)
        var con := "@.str" ++ constants.size ++ " = private unnamed_addr "
            ++ "constant [" ++ len ++ " x i8] c\"" ++ evl ++ "\\00\""
        out("  params[0] = {right};")
        out("  Object opresult{auto_count} = "
            ++ "callmethod({left}, \"{o.value}\", 1, params);")
        o.register := "opresult" ++ auto_count
        auto_count := auto_count + 1
    }
}
method compilecall(o) {
    var args := []
    var obj := ""
    var len := 0
    var evl
    var i := 0
    for (o.with) do { p ->
        var r := compilenode(p)
        args.push(r)
    }
    if (args.size > paramsUsed) then {
        paramsUsed := args.size
    }
    evl := escapestring2(o.value.value)
    if (o.value.kind == "member") then {
        obj := compilenode(o.value.in)
        len := length(o.value.value) + 1
        for (args) do { arg ->
            out("  params[{i}] = {arg};")
            i := i + 1
        }
        out("  Object call{auto_count} = callmethod({obj}, \"{evl}\",")
        out("    {args.size}, params);")
    } else {
        obj := "self"
        len := length(o.value.value) + 1
        for (args) do { arg ->
            out("  params[{i}] = {arg};")
            i := i + 1
        }
        out("  Object call{auto_count} = callmethod(self, \"{evl}\",")
        out("    {args.size}, params);")
    }
    o.register := "call" ++ auto_count
    auto_count := auto_count + 1
}
method compileoctets(o) {
    var escval := ""
    var l := length(o.value) / 2
    var i := 0
    for (o.value) do {c->
        if ((i % 2) == 0) then {
            escval := escval ++ "\"\"\\x\"\""
        }
        escval := escval ++ c
        i := i + 1
    }
    out("  if (octlit{auto_count} == NULL) \{")
    out("    octlit{auto_count} = alloc_Octets(\"{escval}\");")
    out("  \}")
    globals.push("static Object octlit{auto_count};");
    o.register := "octlit" ++ auto_count
    auto_count := auto_count + 1
}
method compileimport(o) {
    out("// Import of " ++ o.value.value)
    var con
    var nm := escapeident(o.value.value)
    var fn := escapestring2(o.value.value)
    var modg := "module_" ++ nm
    out("  if ({modg} == NULL)")
    if (staticmodules.contains(nm)) then {
        out("    {modg} = {modg}_init();")
    } else {
        out("    {modg} = dlmodule(\"{fn}\");")
    }
    out("  Object *var_{nm} = alloc_var();")
    out("  *var_{nm} = {modg};")
    modules.push(nm)
    globals.push("Object {modg}_init();")
    globals.push("Object {modg};")
    auto_count := auto_count + 1
    o.register := "undefined"
}
method compilereturn(o) {
    var reg := compilenode(o.value)
    if (inBlock) then {
        out("  block_return(realself, {reg});")
    } else {
        out("  return {reg};")
    }
    o.register := "undefined"
}
method compilenum(o) {
    var cnum := o.value
    var havedot := false
    for (cnum) do {c->
        if (c == ".") then {
            havedot := true
        }
    }
    if (havedot.not) then {
        cnum := cnum ++ ".0"
    }
    out("  Object num{auto_count} = alloc_Float64({cnum});")
    o.register := "num" ++ auto_count
    auto_count := auto_count + 1
}
method compilenode(o) {
    if (linenum /= o.line) then {
        linenum := o.line
        out("// Begin line " ++ linenum)
        out("  setline({linenum});")
    }
    if (o.kind == "num") then {
        compilenum(o)
    }
    var l := ""
    if (o.kind == "string") then {
        l := length(o.value)
        l := l + 1
        o.value := escapestring2(o.value)
        out("  if (strlit{auto_count} == NULL) \{")
        out("    strlit{auto_count} = alloc_String(\"{o.value}\");")
        out("  \}")
        globals.push("static Object strlit{auto_count};")
        o.register := "strlit" ++ auto_count
        auto_count := auto_count + 1
    }
    if (o.kind == "index") then {
        compileindex(o)
    }
    if (o.kind == "octets") then {
        compileoctets(o)
    }
    if (o.kind == "import") then {
        compileimport(o)
    }
    if (o.kind == "return") then {
        compilereturn(o)
    }
    if ((o.kind == "identifier")
        & ((o.value == "true") | (o.value == "false"))) then {
        var val := 0
        if (o.value == "true") then {
            val := 1
        }
        out("  Object bool" ++ auto_count ++ " = alloc_Boolean({val});")
        o.register := "bool" ++ auto_count
        auto_count := auto_count + 1
    } elseif (o.kind == "identifier") then {
        compileidentifier(o)
    }
    if (o.kind == "defdec") then {
        compiledefdec(o)
    }
    if (o.kind == "vardec") then {
        compilevardec(o)
    }
    if (o.kind == "block") then {
        compileblock(o)
    }
    if (o.kind == "method") then {
        compilemethod(o, "self", topLevelMethodPos)
        topLevelMethodPos := topLevelMethodPos + 1
    }
    if (o.kind == "array") then {
        compilearray(o)
    }
    if (o.kind == "bind") then {
        compilebind(o)
    }
    if (o.kind == "while") then {
        compilewhile(o)
    }
    if (o.kind == "if") then {
        compileif(o)
    }
    if (o.kind == "class") then {
        compileclass(o)
    }
    if (o.kind == "object") then {
        compileobject(o)
    }
    if (o.kind == "member") then {
        compilemember(o)
    }
    if (o.kind == "for") then {
        compilefor(o)
    }
    if ((o.kind == "call")) then {
        if (o.value.value == "print") then {
            var args := []
            for (o.with) do { prm ->
                var r := compilenode(prm)
                args.push(r)
            }
            var parami := 0
            for (args) do { arg ->
                out("  params[{parami}] = {arg};")
                parami := parami + 1
            }
            out("  Object call{auto_count} = gracelib_print(NULL, "
                  ++ args.size ++ ",  params);")
            o.register := "call" ++ auto_count
            auto_count := auto_count + 1
        } elseif ((o.value.kind == "identifier")
                & (o.value.value == "length")) then {
            if (o.with.size == 0) then {
                out("; PP FOLLOWS")
                out(o.pretty(0))
                tmp := "null"
            } else {
                tmp := compilenode(o.with.first)
            }
            out("  Object call" ++ auto_count ++ " = gracelib_length({tmp});")
            o.register := "call" ++ auto_count
            auto_count := auto_count + 1
        } elseif ((o.value.kind == "identifier")
                & (o.value.value == "escapestring")) then {
            tmp := o.with.first
            tmp := ast.astmember("_escape", tmp)
            tmp := ast.astcall(tmp, [])
            o.register := compilenode(tmp)
        } else {
            compilecall(o)
        }
    }
    if (o.kind == "op") then {
        compileop(o)
    }
    out("// compilenode returning " ++ o.register)
    o.register
}
method compile(vl, of, mn, rm, bt) {
    var argv := sys.argv
    var cmd
    values := vl
    outfile := of
    modname := mn
    escmodname := escapeident(modname)
    runmode := rm
    buildtype := bt
    var linkfiles := []
    var ext := false
    if (runmode == "make") then {
        log_verbose("checking imports.")
        for (values) do { v ->
            if (v.kind == "import") then {
                var nm := v.value.value
                var exists := false
                if (io.exists(nm ++ ".gso")) then {
                    exists := true
                } elseif (io.exists(nm ++ ".gcn")) then {
                    if (io.newer(nm ++ ".gcn", nm ++ ".grace")) then {
                        exists := true
                        linkfiles.push(nm ++ ".gcn")
                        staticmodules.push(nm)
                    }
                }
                if (exists.not) then {
                    if (io.exists(nm ++ ".gc")) then {
                        ext := ".gc"
                    }
                    if (io.exists(nm ++ ".grace")) then {
                        ext := ".grace"
                    }
                    if (ext /= false) then {
                        cmd := argv.first ++ " --target c --make " ++ nm ++ ext
                        if (util.verbosity > 30) then {
                            cmd := cmd ++ " --verbose"
                        }
                        if (util.vtag) then {
                            cmd := cmd ++ " --vtag " ++ util.vtag
                        }
                        cmd := cmd ++ " --noexec"
                        if (io.system(cmd).not) then {
                            util.syntax_error("failed processing import of " ++nm ++".")
                        }
                        exists := true
                        linkfiles.push(nm ++ ".gcn")
                        staticmodules.push(nm)
                        ext := false
                    }
                }
                if ((nm == "sys") | (nm == "io")) then {
                    exists := true
                    staticmodules.push(nm)
                }
                if (exists.not) then {
                    util.syntax_error("failed finding import of " ++ nm ++ ".")
                }
            }
        }
    }
    outprint("#include \"gracelib.h\"")
    outprint("#include <stdlib.h>")
    outprint("#pragma weak main")
    outprint("static char compilerRevision[] = \"{buildinfo.gitrevision}\";")
    outprint("static Object undefined;")
    outprint("static Object nothing;")
    outprint("static Object argv;")
    out("Object module_{escmodname}_init() \{")
    out("  Object self = alloc_obj2(100, 100);")
    var modn := "Module<{modname}>"
    out("  setclassname(self, \"{modn}\");")
    out("  Object *var_HashMap = alloc_var();")
    out("  *var_HashMap = alloc_HashMapClassObject();")
    var tmpo := output
    output := []
    for (values) do { l ->
        if ((l.kind == "vardec") | (l.kind == "defdec")
            | (l.kind == "class")) then {
            var tnm := escapeident(l.name.value)
            declaredvars.push(tnm)
            out("  Object *var_{tnm} = alloc_var();")
            out("  *var_{tnm} = undefined;")
        }
    }
    for (values) do { o ->
        compilenode(o)
    }
    for (globals) do {e->
        outprint(e)
    }
    var tmpo2 := output
    output := tmpo
    out("  Object params[{paramsUsed}];")
    for (tmpo2) do { l->
        out(l)
    }
    paramsUsed := 1
    out("  return self;")
    out("}")
    out("int main(int argc, char **argv) \{")
    out("  initprofiling();")
    if (util.extensions.contains("LogCallGraph")) then {
        var lcgfile := util.extensions.get("LogCallGraph")
        out("  enable_callgraph(\"{lcgfile}\");")
    }
    out("  gracelib_argv(argv);")
    out("  Object params[1];")
    out("  undefined = alloc_Undefined();")
    out("  nothing = alloc_Nothing();")
    out("  Object tmp_argv = alloc_List();")
    out("  int i; for (i=0; i<argc; i++) \{")
    out("    params[0] = alloc_String(argv[i]);")
    out("    callmethod(tmp_argv, \"push\", 1,params);")
    out("  \}")
    out("  module_sys_init_argv(tmp_argv);")
    out("  module_{escmodname}_init();")
    out("  gracelib_stats();")
    out("  return 0;")
    out("}")
    log_verbose("writing file.")
    for (topOutput) do { x ->
        outprint(x)
    }
    for (output) do { x ->
        outprint(x)
    }

    if (runmode == "make") then {
        log_verbose("compiling C code.")
        outfile.close
        cmd := "gcc -o {modname}.gcn -c {modname}.c"
        if ((io.system(cmd)).not) then {
            io.error.write("Failed C compilation")
            raise("Fatal.")
        }
        if (util.noexec.not) then {
            log_verbose("linking.")
            var dlbit := ""
            cmd := "ld -ldl -o /dev/null 2>/dev/null"
            if (io.system(cmd)) then {
                dlbit := "-ldl"
            }
            cmd := "gcc -o {modname} -fPIC -Wl,--export-dynamic {dlbit} "
                ++ "{modname}.gcn "
                ++ util.gracelibPath.replace("gracelib.o")
                    with("gracelibn.o") ++ " "
            for (linkfiles) do { fn ->
                cmd := cmd ++ " " ++ fn
            }
            if ((io.system(cmd)).not) then {
                io.error.write("Failed linking")
                raise("Fatal.")
            }
        }
        log_verbose("done.")
        if (buildtype == "run") then {
            cmd := "./" ++ modname
            io.system(cmd)
        }
    }
}