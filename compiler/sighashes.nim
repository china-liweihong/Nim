#
#
#           The Nim Compiler
#        (c) Copyright 2016 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Computes hash values for routine (proc, method etc) signatures.

import ast, md5
export md5.`==`

when false:
  type
    SigHash* = uint32  ## a hash good enough for a filename or a proc signature

  proc sdbmHash(hash: SigHash, c: char): SigHash {.inline.} =
    return SigHash(c) + (hash shl 6) + (hash shl 16) - hash

  template `&=`*(x: var SigHash, c: char) = x = sdbmHash(x, c)
  template `&=`*(x: var SigHash, s: string) =
    for c in s: x = sdbmHash(x, c)

else:
  type
    SigHash* = Md5Digest

  const
    cb64 = [
      "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N",
      "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
      "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n",
      "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z",
      "0", "1", "2", "3", "4", "5", "6", "7", "8", "9a",
      "9b", "9c"]

  proc toBase64a(s: cstring, len: int): string =
    ## encodes `s` into base64 representation.
    result = newStringOfCap(((len + 2) div 3) * 4)
    var i = 0
    while i < len - 2:
      let a = ord(s[i])
      let b = ord(s[i+1])
      let c = ord(s[i+2])
      result.add cb64[a shr 2]
      result.add cb64[((a and 3) shl 4) or ((b and 0xF0) shr 4)]
      result.add cb64[((b and 0x0F) shl 2) or ((c and 0xC0) shr 6)]
      result.add cb64[c and 0x3F]
      inc(i, 3)
    if i < len-1:
      let a = ord(s[i])
      let b = ord(s[i+1])
      result.add cb64[a shr 2]
      result.add cb64[((a and 3) shl 4) or ((b and 0xF0) shr 4)]
      result.add cb64[((b and 0x0F) shl 2)]
    elif i < len:
      let a = ord(s[i])
      result.add cb64[a shr 2]
      result.add cb64[(a and 3) shl 4]

  proc `$`*(u: SigHash): string =
    toBase64a(cast[cstring](unsafeAddr u), sizeof(u))
  proc `&=`(c: var MD5Context, s: string) = md5Update(c, s, s.len)
  proc `&=`(c: var MD5Context, ch: char) = md5Update(c, unsafeAddr ch, 1)

proc hashSym(c: var MD5Context, s: PSym) =
  if sfAnon in s.flags or s.kind == skGenericParam:
    c &= ":anon"
  else:
    var it = s
    while it != nil:
      c &= it.name.s
      c &= "."
      it = it.owner

proc hashTree(c: var MD5Context, n: PNode) =
  template lowlevel(v) =
    md5Update(c, cast[cstring](unsafeAddr(v)), sizeof(v))

  if n == nil:
    c &= "\255"
    return
  let k = n.kind
  c &= char(k)
  # we really must not hash line information. 'n.typ' is debatable but
  # shouldn't be necessary for now and avoids potential infinite recursions.
  case n.kind
  of nkEmpty, nkNilLit, nkType: discard
  of nkIdent:
    c &= n.ident.s
  of nkSym:
    hashSym(c, n.sym)
  of nkCharLit..nkUInt64Lit:
    let v = n.intVal
    lowlevel v
  of nkFloatLit..nkFloat64Lit:
    let v = n.floatVal
    lowlevel v
  of nkStrLit..nkTripleStrLit:
    c &= n.strVal
  else:
    for i in 0.. <n.len: hashTree(c, n.sons[i])

type
  ConsiderFlag* = enum
    considerParamNames

proc hashType(c: var MD5Context, t: PType; flags: set[ConsiderFlag]) =
  # modelled after 'typeToString'
  if t == nil:
    c &= "\254"
    return

  c &= char(t.kind)

  # Every cyclic type in Nim need to be constructed via some 't.sym', so this
  # is actually safe without an infinite recursion check:
  if t.sym != nil and sfAnon notin t.sym.flags:
    # t.n for literals, but not for e.g. objects!
    if t.kind in {tyFloat, tyInt}: c.hashTree(t.n)
    c.hashSym(t.sym)
    return

  case t.kind
  of tyGenericBody, tyGenericInst, tyGenericInvocation:
    for i in countup(0, sonsLen(t) - 1 - ord(t.kind != tyGenericInvocation)):
      c.hashType t.sons[i], flags
  of tyUserTypeClass:
    if t.sym != nil and t.sym.owner != nil:
      c &= t.sym.owner.name.s
    else:
      c &= "unknown typeclass"
  of tyUserTypeClassInst:
    let body = t.sons[0]
    c.hashSym body.sym
    for i in countup(1, sonsLen(t) - 2):
      c.hashType t.sons[i], flags
  of tyFromExpr, tyFieldAccessor:
    c.hashTree(t.n)
  of tyArrayConstr:
    c.hashTree(t.sons[0].n)
    c.hashType(t.sons[1], flags)
  of tyTuple:
    if t.n != nil:
      assert(sonsLen(t.n) == sonsLen(t))
      for i in countup(0, sonsLen(t.n) - 1):
        assert(t.n.sons[i].kind == nkSym)
        c &= t.n.sons[i].sym.name.s
        c &= ':'
        c.hashType(t.sons[i], flags)
        c &= ','
    else:
      for i in countup(0, sonsLen(t) - 1): c.hashType t.sons[i], flags
  of tyRange:
    c.hashTree(t.n)
    c.hashType(t.sons[0], flags)
  of tyProc:
    c &= (if tfIterator in t.flags: "iterator " else: "proc ")
    if considerParamNames in flags and t.n != nil:
      let params = t.n
      for i in 1..<params.len:
        let param = params[i].sym
        c &= param.name.s
        c &= ':'
        c.hashType(param.typ, flags)
        c &= ','
      c.hashType(t.sons[0], flags)
    else:
      for i in 0.. <t.len: c.hashType(t.sons[i], flags)
    c &= char(t.callConv)
    if tfNoSideEffect in t.flags: c &= ".noSideEffect"
    if tfThread in t.flags: c &= ".thread"
  else:
    for i in 0.. <t.len: c.hashType(t.sons[i], flags)
  if tfNotNil in t.flags: c &= "not nil"

proc hashType*(t: PType; flags: set[ConsiderFlag]): SigHash =
  var c: MD5Context
  md5Init c
  hashType c, t, flags
  md5Final c, result

proc hashProc*(s: PSym): SigHash =
  var c: MD5Context
  md5Init c
  hashType c, s.typ, {considerParamNames}

  var m = s
  while m.kind != skModule: m = m.owner
  let p = m.owner
  assert p.kind == skPackage
  c &= p.name.s
  c &= "."
  c &= m.name.s

  md5Final c, result

proc hashOwner*(s: PSym): SigHash =
  var c: MD5Context
  md5Init c
  var m = s
  while m.kind != skModule: m = m.owner
  let p = m.owner
  assert p.kind == skPackage
  c &= p.name.s
  c &= "."
  c &= m.name.s

  md5Final c, result