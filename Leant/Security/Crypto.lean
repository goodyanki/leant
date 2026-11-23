namespace Leant.Security.Crypto

/-- Computes HMAC-SHA256 over `data` using `key`, returning a 32-byte MAC. -/
@[extern "leant_c_hmac_sha256"]
opaque hmacSha256 (key : @& ByteArray) (data : @& ByteArray) : ByteArray

/-- Constant-time byte array equality comparison (resistant to timing side channels). -/
@[extern "leant_c_ct_eq"]
opaque ctEq (a : @& ByteArray) (b : @& ByteArray) : Bool

/-- Generates `len` cryptographically secure random bytes from the OS CSPRNG. -/
@[extern "leant_c_random_bytes"]
opaque randomBytes (len : USize) : IO ByteArray

private def hexDigit (n : UInt8) : Char :=
  if n < 10 then Char.ofNat (48 + n.toNat)
  else Char.ofNat (87 + n.toNat) -- 'a'..'f'

/-- Encodes a `ByteArray` into lowercase hexadecimal ASCII. -/
def toHex (ba : ByteArray) : String :=
  let rec go (i : Nat) (acc : String) : String :=
    if h : i < ba.size then
      let b := ba[i]
      let acc := acc.push (hexDigit (b / 16)) |>.push (hexDigit (b % 16))
      go (i + 1) acc
    else
      acc
  termination_by ba.size - i
  go 0 ""

private def parseHexNibble (b : UInt8) : Option UInt8 :=
  if b >= 48 && b <= 57 then some (b - 48)
  else if b >= 97 && b <= 102 then some (b - 97 + 10)
  else if b >= 65 && b <= 70 then some (b - 65 + 10)
  else none

private def fromHexLoop (bytes : ByteArray) (i : Nat) (acc : ByteArray) : Option ByteArray :=
  if h : i + 1 < bytes.size then
    match parseHexNibble bytes[i], parseHexNibble bytes[i + 1] with
    | some hi, some lo => fromHexLoop bytes (i + 2) (acc.push (hi * 16 + lo))
    | _, _ => none
  else
    some acc
termination_by bytes.size - i

/-- Decodes a hexadecimal ASCII string into a `ByteArray`. -/
def fromHex (s : String) : Option ByteArray :=
  let bytes := s.toUTF8
  if bytes.size % 2 != 0 then
    none
  else
    fromHexLoop bytes 0 ByteArray.empty

/-- Generates `numBytes` of OS CSPRNG randomness encoded as lowercase hex. -/
def randomHex (numBytes : USize := 32) : IO String := do
  let bytes ← randomBytes numBytes
  pure (toHex bytes)

/-- Constant-time string comparison via UTF-8 byte arrays. -/
def ctEqString (a b : String) : Bool :=
  ctEq a.toUTF8 b.toUTF8

end Leant.Security.Crypto
