# 1. Allow the UI to "see" that the 'kv' engine exists
path "sys/mounts" {
  capabilities = ["read"]
}

# 2. Allow the UI to list folders so you can click through them
# Note: the metadata path is what the UI uses for the folder tree
path "kv/metadata/*" {
  capabilities = ["list", "read"]
}

# 3. Your existing data permissions
path "kv/data/env/*" {
  capabilities = ["read", "list"]
}

path "kv/data/env" {
  capabilities = ["read", "list"]
}
