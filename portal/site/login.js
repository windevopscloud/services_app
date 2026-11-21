document.getElementById("title").textContent = P.title;
const go = document.getElementById("go");
go.addEventListener("click", startLogin);
startLogin().catch((e) => {
  document.getElementById("msg").textContent = "Could not start sign in: " + e.message;
  go.hidden = false;
});
