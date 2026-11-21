(async function () {
  document.getElementById("title").textContent = P.title;
  const out = document.getElementById("out");
  const info = document.getElementById("info");
  let tok;
  try {
    tok = await finishLogin();
  } catch (e) {
    info.textContent = e.message;
    return;
  }
  if (!tok) {
    location.replace("/"); // no code in the URL: start the login again
    return;
  }
  const c = claims(tok.access_token);
  info.textContent = `Signed in as ${c.username || c.sub}. Scopes: ${c.scope}. Token expires ${new Date(c.exp * 1000).toLocaleTimeString()}.`;

  const box = document.getElementById("buttons");
  P.buttons.forEach((b) => {
    const el = document.createElement("button");
    el.textContent = b.label;
    el.addEventListener("click", async () => {
      out.textContent = `GET ${b.path} ...`;
      try {
        const r = await fetch(b.path, { headers: { authorization: "Bearer " + tok.access_token } });
        const text = await r.text();
        let shown = text;
        try { shown = JSON.stringify(JSON.parse(text), null, 2); } catch (_) {}
        out.textContent = `HTTP ${r.status}\n` + shown;
      } catch (e) {
        out.textContent = "Request failed: " + e.message;
      }
    });
    box.appendChild(el);
  });
  document.getElementById("logout").addEventListener("click", logout);
})();
