# 1. Allow the UI to "see" that the 'kv' engine exists
path "sys/mounts" {
  capabilities = ["read"]
}

# 2. Metadata permissions: Required for the UI to list folders 
# and for the user to delete secret names/keys.
path "kv/metadata/env/*" {
  capabilities = ["list", "read", "delete"]
}

# 3. Data permissions: The actual values inside the secrets
path "kv/data/env/*" {
  capabilities = ["create", "read", "update", "patch", "delete", "list"]
}

# 4. Permissions for the base 'env' path itself
path "kv/data/env" {
  capabilities = ["create", "read", "update", "patch", "delete", "list"]
}
