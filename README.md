### OpenBao Administration Reference

---

## 1. Namespaces (Isolation)

Namespaces are virtualized instances of OpenBao.

* **Create (CLI):** `bao namespace create engineering`
* **Create (UI):** Side Navigation > **Namespaces** > **Create namespace**.
* **Access:** Use the top-right dropdown in the UI to switch context into a namespace.
* **Pathing:** In a child namespace, paths are prefixed: `engineering/kv/data/...`

---

## 2. User Authentication (Userpass)

Identity management using local usernames and passwords.

* **Enable Method:** `bao auth enable userpass`
* **Create User:** ```bash
bao write auth/userpass/users/user_name 
password="password123" 
token_policies="default"
```

```


* **Edit User (UI):** **Access** > **Auth Methods** > **Userpass** > **Users** tab.

---

## 3. Comprehensive Policy Guide

Policies must target `data/` for values and `metadata/` for UI browsing.

### Standard Dev Policy (`dev-policy.hcl`)

```hcl
# UI Discovery
path "sys/mounts" { capabilities = ["read"] }

# UI Folder Browsing
path "kv/metadata/*" { capabilities = ["list", "read", "delete"] }

# Namespace Visibility
path "sys/namespaces/engineering" { capabilities = ["read"] }

# Full CRUD on Environment Secrets
path "kv/data/env/*" {
  capabilities = ["create", "read", "update", "patch", "delete", "list"]
}

```

---

## 4. Permission Mapping (Granting Access)

Association of policies to users is a **replacement** action.

* **Grant Multiple Policies (CLI):**
```bash
bao write auth/userpass/users/username \
    token_policies="policy1,policy2,policy3"

```


* **Grant in UI:** **Access** > **Userpass** > **Edit User** > **Generated Token's Policies** (Comma-separated list).

---

## 5. Capabilities Reference Table

| Capability | Functional Action |
| --- | --- |
| **`read`** | Retrieve secret values or metadata. |
| **`list`** | View keys in a directory (Crucial for UI). |
| **`create`** | Write a new path that doesn't exist. |
| **`update`** | Overwrite existing data / Create new version. |
| **`patch`** | Partial update of JSON keys. |
| **`delete`** | Soft-delete a version (Recoverable). |
| **`destroy`** | Permanent data erasure from disk. |
| **`purge`** | Delete all versions and metadata. |
| **`deny`** | Absolute block (Highest priority). |

---

## 6. Verification Commands

Run these in the UI Terminal (`>_`) to debug:

* **Check Active Policies:** `bao token lookup`
* **Test KV Read:** `bao kv get kv/env/backend`
* **Test List:** `bao kv list kv/env/`
