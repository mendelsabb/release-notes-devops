"use strict";

const $ = (sel) => document.querySelector(sel);
const historyEl = $("#history");
const form = $("#release-form");
const feedback = $("#feedback");
const submit = $("#submit");
const timeFmt = new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" });

function showFeedback(kind, text) {
  feedback.className = `feedback ${kind}`;
  feedback.textContent = text;
}

// FastAPI returns either {"detail": "msg"} or a list of validation errors.
function errorMessage(body, status) {
  if (body && typeof body.detail === "string") return body.detail;
  if (body && Array.isArray(body.detail) && body.detail.length) {
    const first = body.detail[0];
    const field = Array.isArray(first.loc) ? first.loc[first.loc.length - 1] : "input";
    return `${field}: ${first.msg}`;
  }
  return `Request failed (HTTP ${status})`;
}

async function loadVersion() {
  try {
    const res = await fetch("/version");
    const info = await res.json();
    $("#version-badge").textContent = `v${info.version} · ${info.git_sha.slice(0, 7)}`;
    const env = $("#env-badge");
    env.textContent = info.environment;
    env.hidden = false;
  } catch {
    $("#version-badge").textContent = "version unknown";
  }
}

function renderReleases(releases) {
  historyEl.replaceChildren();
  if (releases.length === 0) {
    const p = document.createElement("p");
    p.className = "muted empty";
    p.textContent = "No releases recorded yet. Record the first one.";
    historyEl.append(p);
    return;
  }
  const tpl = $("#release-item");
  for (const r of releases) {
    const node = tpl.content.cloneNode(true);
    node.querySelector(".release-version").textContent = r.version;
    const t = node.querySelector(".release-time");
    t.dateTime = r.released_at;
    t.textContent = timeFmt.format(new Date(r.released_at));
    node.querySelector(".release-desc").textContent = r.description;
    historyEl.append(node);
  }
}

async function loadReleases() {
  historyEl.setAttribute("aria-busy", "true");
  try {
    const res = await fetch("/api/releases?limit=100");
    const body = await res.json().catch(() => null);
    if (!res.ok) throw new Error(errorMessage(body, res.status));
    renderReleases(body);
  } catch (err) {
    historyEl.replaceChildren();
    const p = document.createElement("p");
    p.className = "feedback err";
    p.textContent = `Could not load releases: ${err.message}`;
    historyEl.append(p);
  } finally {
    historyEl.setAttribute("aria-busy", "false");
  }
}

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  if (!form.reportValidity()) return;
  submit.disabled = true;
  showFeedback("", "");
  const payload = {
    version: form.version.value.trim(),
    description: form.description.value.trim(),
  };
  try {
    const res = await fetch("/api/releases", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    const body = await res.json().catch(() => null);
    if (!res.ok) throw new Error(errorMessage(body, res.status));
    showFeedback("ok", `Release ${body.version} recorded.`);
    form.reset();
    await loadReleases();
  } catch (err) {
    showFeedback("err", err.message);
  } finally {
    submit.disabled = false;
  }
});

$("#refresh").addEventListener("click", loadReleases);
loadVersion();
loadReleases();
