import Saas

def main : IO Unit := do
  let dbPath := (← IO.getEnv "SAAS_DB_PATH").getD ":memory:"
  let secret := (← IO.getEnv "SAAS_SECRET").getD "dev-secret-change-me"
  let app ← buildSaasApp dbPath secret true
  app.run "127.0.0.1:8080"
