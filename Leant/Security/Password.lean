namespace Leant.Security.Password

/-- Hashes a plaintext password using Argon2id with a fresh 16-byte OS CSPRNG salt,
    returning a standard PHC-formatted string (`$argon2id$v=19$...`). -/
@[extern "leant_c_argon2_hash"]
opaque hash (password : @& String) : IO String

/-- Verifies a plaintext password against a PHC-formatted Argon2 hash in constant time. -/
@[extern "leant_c_argon2_verify"]
opaque verify (password : @& String) (phcHash : @& String) : Bool

end Leant.Security.Password
