path "kv/data/env" {
  capabilities = ["read", "list"]
}

path "kv/data/env/*" {
  capabilities = ["read", "list"]
}