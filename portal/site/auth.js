// Authorization code flow with PKCE against the Cognito hosted login.
const P = window.PORTAL;
const redirectUri = () => location.origin + P.redirectPath;

const b64url = (buf) =>
  btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const rand = (n) => b64url(crypto.getRandomValues(new Uint8Array(n)));

async function startLogin() {
  const verifier = rand(48);
  const state = rand(16);
  const challenge = b64url(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier)));
  sessionStorage.setItem("pkce_verifier", verifier);
  sessionStorage.setItem("pkce_state", state);
  const q = new URLSearchParams({
    response_type: "code",
    client_id: P.clientId,
    redirect_uri: redirectUri(),
    scope: P.scope,
    state,
    code_challenge: challenge,
    code_challenge_method: "S256",
  });
  location.assign(`https://${P.cognitoDomain}/oauth2/authorize?${q}`);
}

async function finishLogin() {
  const params = new URLSearchParams(location.search);
  const code = params.get("code");
  if (!code) return null;
  if (params.get("state") !== sessionStorage.getItem("pkce_state")) throw new Error("State mismatch");
  const body = new URLSearchParams({
    grant_type: "authorization_code",
    client_id: P.clientId,
    code,
    redirect_uri: redirectUri(),
    code_verifier: sessionStorage.getItem("pkce_verifier"),
  });
  const r = await fetch(`https://${P.cognitoDomain}/oauth2/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body,
  });
  if (!r.ok) throw new Error("Token exchange failed: " + r.status + " " + (await r.text()));
  sessionStorage.removeItem("pkce_verifier");
  sessionStorage.removeItem("pkce_state");
  history.replaceState({}, "", P.redirectPath); // drop ?code=... from the address bar
  return r.json();
}

function logout() {
  const q = new URLSearchParams({ client_id: P.clientId, logout_uri: location.origin + "/" });
  location.assign(`https://${P.cognitoDomain}/logout?${q}`);
}

function claims(jwt) {
  const p = jwt.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
  return JSON.parse(atob(p));
}
