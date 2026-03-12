// biome-ignore-all lint/style/useNamingConvention: Openbao

import vault from 'node-vault';
import 'dotenv/config';

const ROLE_ID = process.env.BAO_ROLE_ID;
const SECRET_ID = process.env.BAO_SECRET_ID;

const Client = vault({
  apiVersion: 'v1',
  endpoint: 'http://localhost:8200',
});

async function getSecrets() {
  try {
    const login = await Client.approleLogin({
      role_id: ROLE_ID,
      secret_id: SECRET_ID,
    });

    Client.token = login.auth.client_token;

    const response = await Client.read('kv/data/env/backend');

    const secrets = response.data.data;

    console.log({ secrets });
  } catch (err) {
    console.error('Error fetching from OpenBao:', err);
  }
}

getSecrets();
