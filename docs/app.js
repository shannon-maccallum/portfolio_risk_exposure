/* Mandate demo app. Plain JavaScript + ethers v6, no build step. */
(() => {
  const { ethers } = window;
  const C = window.CONTRACTS;

  const CHAIN = {
    id: 10143,
    hex: "0x279f",
    name: "Monad Testnet",
    rpc: "https://testnet-rpc.monad.xyz",
    explorer: "https://testnet.monadvision.com",
  };
  const THEMES = ["AI", "Oil"];
  const STOCKS = ["NVDA", "AMD", "MSFT", "AVGO", "GOOGL", "XOM", "CVX"];
  // Default scores from 10-K filings (percent): [AI, Oil]. See exposure_10k.csv.
  const TEN_K = { NVDA: [89.7, 0], AMD: [47.9, 0], MSFT: [41.5, 0], AVGO: [31.3, 0], GOOGL: [15.5, 0], XOM: [0, 88.6], CVX: [0, 100] };
  // Latest verified closing prices (date in README): NVDA/AMD/MSFT/AVGO Nov 10, GOOGL Nov 6, XOM/CVX Nov 12, 2026.
  const LAST_CLOSE = { NVDA: 168.89, AMD: 515.21, MSFT: 533.16, AVGO: 331.98, GOOGL: 284.78, XOM: 169.78, CVX: 216.35 };
  const TIER = ["None", "Low", "Medium", "High"];
  const GAS_BUFFER = 115n; // Monad charges the gas limit, so keep the buffer tight (15%).
  const THEME_ID = Object.fromEntries(THEMES.map((t) => [t, ethers.id(t)]));

  // One interface holding every custom error, so reverts from any contract decode to plain English.
  const ERR_IFACE = new ethers.Interface(
    Object.values(C).flatMap((c) => c.abi.filter((x) => x.type === "error"))
  );
  const FUND_IFACE = new ethers.Interface(C.ThemeFund.abi);
  const FACTORY_IFACE = new ethers.Interface(C.FundFactory.abi);

  const S = {
    reader: new ethers.JsonRpcProvider(CHAIN.rpc, CHAIN.id, { staticNetwork: true }),
    browser: null,
    signer: null,
    account: null,
    platformAddr: null,
    oracle: null,
    exchange: null,
    factory: null,
    usd: null,
    stocks: {}, // symbol -> address
    symbolOf: {}, // lowercased address -> symbol
    oracleOwner: null,
    oracleData: {}, // symbol -> { price, ai, oil }
    fund: null, // selected fund address
    fundInfo: null,
  };

  const $ = (id) => document.getElementById(id);

  // ------------------------------------------------------------ formatting

  const fmtUsd = (wei, dp = 2) =>
    "$" + Number(ethers.formatUnits(wei, 18)).toLocaleString(undefined, { minimumFractionDigits: dp, maximumFractionDigits: dp });
  const fmtTok = (wei, dp = 4) => Number(ethers.formatUnits(wei, 18)).toLocaleString(undefined, { maximumFractionDigits: dp });
  const pct = (bps) => (Number(bps) / 100).toFixed(1) + "%";
  const short = (a) => a.slice(0, 6) + "…" + a.slice(-4);
  const tierOf = (bps) => (bps >= 4000 ? 3 : bps >= 1500 ? 2 : bps > 0 ? 1 : 0);
  const tierTag = (t) => `<span class="tier t${t}">${TIER[t]}</span>`;
  const txLink = (h) => `<a href="${CHAIN.explorer}/tx/${h}" target="_blank" rel="noopener">view tx</a>`;
  const addrLink = (a) => `${CHAIN.explorer}/address/${a}`;

  function log(msg, cls = "") {
    const li = document.createElement("li");
    li.className = cls;
    li.innerHTML = `<span class="muted">${new Date().toLocaleTimeString()}</span> ${msg}`;
    $("log").prepend(li);
  }

  function decodeError(e) {
    const data = e?.data ?? e?.info?.error?.data ?? e?.error?.data;
    if (typeof data === "string" && data.startsWith("0x") && data.length >= 10) {
      try {
        const p = ERR_IFACE.parseError(data);
        if (p) {
          if (p.name === "InvalidBasket") return p.args[0];
          return p.name + (p.args.length ? ": " + p.args.join(", ") : "");
        }
      } catch (_) { /* fall through */ }
    }
    if (e?.revert) return e.revert.name + " " + (e.revert.args || []).join(", ");
    if (e?.code === "ACTION_REJECTED") return "You rejected the transaction in MetaMask";
    return e?.shortMessage || e?.reason || e?.message || String(e);
  }

  function setResult(id, text, ok, big = false) {
    const el = $(id);
    el.textContent = text;
    el.className = "result " + (ok === true ? "ok" : ok === false ? "bad" : "") + (big ? " big" : "");
  }

  // ------------------------------------------------------------ wallet

  async function connect() {
    if (!window.ethereum) {
      alert("MetaMask not found. Install it, then reload this page.");
      return;
    }
    try {
      await window.ethereum.request({ method: "eth_requestAccounts" });
      await ensureChain();
      S.browser = new ethers.BrowserProvider(window.ethereum);
      S.signer = await S.browser.getSigner();
      S.account = await S.signer.getAddress();
      $("account").textContent = short(S.account);
      $("connectBtn").textContent = "Connected";
      window.ethereum.on?.("accountsChanged", () => location.reload());
      window.ethereum.on?.("chainChanged", () => location.reload());
      enableButtons();
      if (S.platformAddr) await loadPlatform(); // re-read everything through the wallet's connection
      else await refreshAll();
    } catch (e) {
      log("Connect failed: " + decodeError(e), "bad");
    }
  }

  async function ensureChain() {
    const current = await window.ethereum.request({ method: "eth_chainId" });
    if (current.toLowerCase() === CHAIN.hex) return;
    try {
      await window.ethereum.request({ method: "wallet_switchEthereumChain", params: [{ chainId: CHAIN.hex }] });
    } catch (e) {
      if (e.code === 4902 || e?.data?.originalError?.code === 4902) {
        await window.ethereum.request({
          method: "wallet_addEthereumChain",
          params: [{
            chainId: CHAIN.hex,
            chainName: CHAIN.name,
            nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
            rpcUrls: [CHAIN.rpc],
            blockExplorerUrls: [CHAIN.explorer],
          }],
        });
      } else {
        throw e;
      }
    }
  }

  function enableButtons() {
    const on = !!S.signer;
    ["deployBtn", "faucetBtn", "previewLaunchBtn", "launchBtn", "depositBtn", "redeemBtn", "proposeBtn", "enforceBtn"].forEach(
      (id) => ($(id).disabled = !on || (id !== "deployBtn" && !S.platformAddr))
    );
  }

  /** Send a transaction with a tight gas limit, log it, wait for it. */
  async function send(label, contract, method, args = []) {
    if (!S.signer) throw new Error("Connect MetaMask first");
    const c = contract.connect(S.signer);
    const est = await c[method].estimateGas(...args);
    const tx = await c[method](...args, { gasLimit: (est * GAS_BUFFER) / 100n });
    log(`${label}: sent… ${txLink(tx.hash)}`);
    const receipt = await tx.wait();
    log(`${label}: confirmed in block ${receipt.blockNumber} ${txLink(tx.hash)}`, "ok");
    return receipt;
  }

  // ------------------------------------------------------------ platform

  function platformFromSources() {
    const q = new URLSearchParams(location.search).get("platform");
    if (q && ethers.isAddress(q)) return q;
    const cfg = window.CONFIG?.platform;
    if (cfg && ethers.isAddress(cfg)) return cfg;
    try {
      const ls = localStorage.getItem("mandate.platform");
      if (ls && ethers.isAddress(ls)) return ls;
    } catch (_) { /* storage unavailable */ }
    return null;
  }

  function savePlatform(addr) {
    S.platformAddr = addr;
    try { localStorage.setItem("mandate.platform", addr); } catch (_) { /* ignore */ }
    const url = new URL(location.href);
    url.searchParams.set("platform", addr);
    history.replaceState(null, "", url);
  }

  async function deployPlatform() {
    try {
      await ensureChain();
      const f = new ethers.ContractFactory(C.Platform.abi, C.Platform.bytecode, S.signer);
      const dtx = await f.getDeployTransaction(THEMES, STOCKS);
      const est = await S.signer.estimateGas(dtx);
      log(`Deploying platform (gas ≈ ${est.toLocaleString()})…`);
      const c = await f.deploy(THEMES, STOCKS, { gasLimit: (est * GAS_BUFFER) / 100n });
      log(`Platform deploy sent… ${txLink(c.deploymentTransaction().hash)}`);
      await c.waitForDeployment();
      const addr = await c.getAddress();
      log(`Platform deployed at <a href="${addrLink(addr)}" target="_blank">${addr}</a>. Next: post data to the oracle.`, "ok");
      savePlatform(addr);
      await loadPlatform();
      $("oracleAdmin").open = true;
    } catch (e) {
      log("Deploy failed: " + decodeError(e), "bad");
    }
  }

  async function loadPlatform() {
    const r = S.browser || S.reader;
    const p = new ethers.Contract(S.platformAddr, C.Platform.abi, r);
    const [o, x, f] = await Promise.all([p.oracle(), p.exchange(), p.factory()]);
    S.oracle = new ethers.Contract(o, C.ExposureOracle.abi, r);
    S.exchange = new ethers.Contract(x, C.MockExchange.abi, r);
    S.factory = new ethers.Contract(f, C.FundFactory.abi, r);
    S.usd = new ethers.Contract(await S.exchange.usd(), C.MockToken.abi, r);
    // Monad nodes can lag a moment behind a just-confirmed block, so retry until the stocks appear.
    let addrs = [];
    for (let i = 0; i < 8 && addrs.length === 0; i++) {
      addrs = await S.exchange.allStocks().catch(() => []);
      if (addrs.length === 0) await new Promise((r) => setTimeout(r, 1500));
    }
    if (addrs.length === 0) throw new Error("Platform found but its stocks are not readable yet. Refresh the page in a few seconds.");
    const syms = await Promise.all(addrs.map((a) => new ethers.Contract(a, C.MockToken.abi, r).symbol()));
    S.stocks = {};
    S.symbolOf = {};
    syms.forEach((s, i) => { S.stocks[s] = addrs[i]; S.symbolOf[addrs[i].toLowerCase()] = s; });
    S.oracleOwner = await S.oracle.owner();

    $("setupSection").classList.add("hidden");
    $("platformSection").classList.remove("hidden");
    $("addresses").innerHTML =
      `Platform <a href="${addrLink(S.platformAddr)}" target="_blank">${short(S.platformAddr)}</a> · ` +
      `Oracle <a href="${addrLink(o)}" target="_blank">${short(o)}</a> · ` +
      `Exchange <a href="${addrLink(x)}" target="_blank">${short(x)}</a> · ` +
      `Factory <a href="${addrLink(f)}" target="_blank">${short(f)}</a> · ` +
      `Oracle owner ${short(S.oracleOwner)}`;
    enableButtons();
    buildStaticUi();
    await refreshAll();
  }

  // ------------------------------------------------------------ oracle

  async function loadOracle() {
    const rows = await Promise.all(
      Object.entries(S.stocks).map(async ([sym, a]) => {
        const [price, ai, oil] = await Promise.all([
          S.oracle.priceOf(a), S.oracle.scoreBps(a, THEME_ID.AI), S.oracle.scoreBps(a, THEME_ID.Oil),
        ]);
        return [sym, { price, ai: Number(ai), oil: Number(oil) }];
      })
    );
    S.oracleData = Object.fromEntries(rows);
    const tb = $("oracleTable").querySelector("tbody");
    tb.innerHTML = rows
      .map(([sym, d]) =>
        `<tr><td><b>${sym}</b></td><td>${d.price > 0n ? fmtUsd(d.price) : '<span class="muted">not posted</span>'}</td>` +
        `<td>${pct(d.ai)} ${tierTag(tierOf(d.ai))}</td><td>${pct(d.oil)} ${tierTag(tierOf(d.oil))}</td></tr>`)
      .join("");
    // Pre-fill the editor with on-chain values, or 10-K defaults before the first post.
    const eb = $("oracleEdit").querySelector("tbody");
    if (!eb.dataset.filled && rows.length) {
      eb.innerHTML = rows
        .map(([sym, d]) => {
          const posted = d.price > 0n;
          const ai = posted ? d.ai / 100 : TEN_K[sym]?.[0] ?? 0;
          const oil = posted ? d.oil / 100 : TEN_K[sym]?.[1] ?? 0;
          const price = posted ? ethers.formatUnits(d.price, 18) : LAST_CLOSE[sym] ?? "";
          return `<tr data-sym="${sym}"><td>${sym}</td><td><input class="pPrice" type="number" step="0.01" value="${price}" placeholder="price"></td>` +
            `<td><input class="pAi" type="number" step="0.1" value="${ai}"></td><td><input class="pOil" type="number" step="0.1" value="${oil}"></td></tr>`;
        })
        .join("");
      eb.dataset.filled = "1";
    }
  }

  async function fetchFmp() {
    const key = $("fmpKey").value.trim();
    if (!key) { alert("Paste an FMP API key first, or type prices in by hand."); return; }
    let got = 0;
    for (const tr of $("oracleEdit").querySelectorAll("tbody tr")) {
      const sym = tr.dataset.sym;
      try {
        const res = await fetch(`https://financialmodelingprep.com/stable/quote?symbol=${encodeURIComponent(sym)}&apikey=${encodeURIComponent(key)}`);
        const js = await res.json();
        const price = Array.isArray(js) && js[0]?.price;
        if (price) { tr.querySelector(".pPrice").value = Number(price).toFixed(2); got++; }
      } catch (e) {
        log(`FMP fetch failed for ${sym}: ${e.message}`, "bad");
      }
    }
    log(`Fetched ${got} of ${STOCKS.length} prices from FMP. Check them, then post.`, got ? "ok" : "bad");
  }

  async function postOracle() {
    try {
      if (S.account?.toLowerCase() !== S.oracleOwner?.toLowerCase()) throw new Error("Only the oracle owner can post data");
      const tokens = [], prices = [], scores = [];
      for (const tr of $("oracleEdit").querySelectorAll("tbody tr")) {
        const sym = tr.dataset.sym;
        const p = tr.querySelector(".pPrice").value;
        if (!p || Number(p) <= 0) throw new Error(`Enter a price for ${sym}`);
        const ai = Math.round(Number(tr.querySelector(".pAi").value) * 100);
        const oil = Math.round(Number(tr.querySelector(".pOil").value) * 100);
        if ([ai, oil].some((v) => !(v >= 0 && v <= 10000))) throw new Error(`Scores for ${sym} must be 0 to 100`);
        tokens.push(S.stocks[sym]);
        prices.push(ethers.parseUnits(String(p), 18));
        scores.push(ai, oil);
      }
      await send("Post oracle data", S.oracle, "post", [tokens, prices, [THEME_ID.AI, THEME_ID.Oil], scores]);
      await refreshAll();
    } catch (e) {
      log("Post failed: " + decodeError(e), "bad");
    }
  }

  async function postDrift() {
    try {
      const sym = $("driftStock").value;
      const theme = $("driftTheme").value;
      const bps = Math.round(Number($("driftScore").value) * 100);
      await send(`New filing: ${sym} ${theme} → ${pct(bps)}`, S.oracle, "setScore", [S.stocks[sym], THEME_ID[theme], bps]);
      await refreshAll();
    } catch (e) {
      log("Score update failed: " + decodeError(e), "bad");
    }
  }

  // ------------------------------------------------------------ basket editors

  function basketEditor(containerId, sumId, rows) {
    const box = $(containerId);
    box.innerHTML = "";
    rows.forEach(([sym, w]) => addBasketRow(containerId, sumId, sym, w));
    updateSum(containerId, sumId);
  }

  function addBasketRow(containerId, sumId, sym = "NVDA", w = 0) {
    const div = document.createElement("div");
    div.className = "basketrow";
    div.innerHTML =
      `<select>${Object.keys(S.stocks).map((s) => `<option ${s === sym ? "selected" : ""}>${s}</option>`).join("")}</select>` +
      `<input type="number" step="0.1" min="0" max="100" value="${w}"><span>%</span><button class="ghost">✕</button>`;
    div.querySelector("button").onclick = () => { div.remove(); updateSum(containerId, sumId); };
    div.querySelector("input").oninput = () => updateSum(containerId, sumId);
    $(containerId).appendChild(div);
    updateSum(containerId, sumId);
  }

  function readBasket(containerId) {
    const a = [], w = [];
    for (const row of $(containerId).querySelectorAll(".basketrow")) {
      a.push(S.stocks[row.querySelector("select").value]);
      w.push(Math.round(Number(row.querySelector("input").value) * 100));
    }
    return [a, w];
  }

  function updateSum(containerId, sumId) {
    const [, w] = readBasket(containerId);
    const total = w.reduce((x, y) => x + y, 0);
    $(sumId).textContent = `Total ${pct(total)}` + (total === 10000 ? " ✓" : " (must be 100%)");
  }

  // ------------------------------------------------------------ launch

  function launchArgs() {
    const [a, w] = readBasket("launchBasket");
    const rules = [
      { theme: THEME_ID.AI, minBps: Math.round(Number($("ruleAiMin").value) * 100), maxBps: 10000, maxTier: 3 },
      { theme: THEME_ID.Oil, minBps: 0, maxBps: Math.round(Number($("ruleOilMax").value) * 100), maxTier: Number($("ruleOilTier").value) },
    ];
    return [$("fundName").value.trim(), $("fundSymbol").value.trim().toUpperCase(), a, w, rules];
  }

  async function previewLaunch() {
    try {
      const args = launchArgs();
      await S.factory.connect(S.signer).createFund.staticCall(...args);
      setResult("launchResult", "✓ Passes every rule. Ready to launch.", true);
    } catch (e) {
      setResult("launchResult", "✗ Rejected: " + decodeError(e), false);
    }
  }

  async function launch() {
    try {
      const args = launchArgs();
      if (!args[0] || !args[1]) throw new Error("Give the fund a name and ticker");
      await S.factory.connect(S.signer).createFund.staticCall(...args); // surface rule errors before MetaMask
      const receipt = await send(`Launch $${args[1]}`, S.factory, "createFund", args);
      const ev = receipt.logs.map((l) => { try { return FACTORY_IFACE.parseLog(l); } catch (_) { return null; } }).find((x) => x?.name === "FundCreated");
      setResult("launchResult", `✓ $${args[1]} launched`, true);
      await loadFunds();
      if (ev) await selectFund(ev.args.fund);
    } catch (e) {
      setResult("launchResult", "✗ " + decodeError(e), false);
    }
  }

  // ------------------------------------------------------------ funds

  async function loadFunds() {
    const list = await S.factory.allFunds();
    const box = $("fundList");
    if (!list.length) { box.innerHTML = '<span class="muted">No funds yet. Launch the first one above.</span>'; return; }
    const r = S.browser || S.reader;
    const names = await Promise.all(list.map((a) => new ethers.Contract(a, C.ThemeFund.abi, r).symbol()));
    box.innerHTML = "";
    list.forEach((a, i) => {
      const b = document.createElement("button");
      b.textContent = "$" + names[i];
      b.title = a;
      if (S.fund && a.toLowerCase() === S.fund.toLowerCase()) b.classList.add("active");
      b.onclick = () => selectFund(a);
      box.appendChild(b);
    });
  }

  async function selectFund(addr) {
    S.fund = addr;
    $("fundSection").classList.remove("hidden");
    setResult("proposeResult", "");
    setResult("enforceResult", "");
    await loadFunds();
    await loadFund(true);
    $("fundSection").scrollIntoView({ behavior: "smooth", block: "start" });
  }

  function fundContract() {
    return new ethers.Contract(S.fund, C.ThemeFund.abi, S.browser || S.reader);
  }

  async function loadFund(resetEditor = false) {
    if (!S.fund) return;
    const f = fundContract();
    const [name, sym, price, nav, supply, passed, failed, lastFail, assets, weights, rules, creator] = await Promise.all([
      f.name(), f.symbol(), f.sharePrice(), f.nav(), f.totalSupply(), f.checksPassed(), f.checksFailed(),
      f.lastFailReason(), f.assets(), f.weights(), f.rules(), f.creator(),
    ]);
    const mine = S.account ? await f.balanceOf(S.account) : 0n;
    S.fundInfo = { sym, assets, weights, rules, creator, mine };

    $("fundTitle").textContent = `$${sym} · ${name}`;
    $("fundLink").textContent = S.fund;
    $("fundLink").href = addrLink(S.fund);
    $("sPrice").textContent = fmtUsd(price);
    $("sNav").textContent = fmtUsd(nav);
    $("sSupply").textContent = fmtTok(supply, 2);
    $("sMine").textContent = fmtTok(mine, 2) + " $" + sym;
    $("receipts").innerHTML =
      `<div class="receipt"><span class="label">Rule checks passed</span><b class="ok">${passed}</b></div>` +
      `<div class="receipt"><span class="label">Breaches caught</span><b>${failed}</b></div>` +
      (lastFail ? `<div class="receipt"><span class="label">Last rejection</span><b class="small">${lastFail}</b></div>` : "");

    const r = S.browser || S.reader;
    const held = await Promise.all(assets.map((a) => new ethers.Contract(a, C.MockToken.abi, r).balanceOf(S.fund)));
    $("holdTable").querySelector("tbody").innerHTML = assets.length
      ? assets.map((a, i) => {
          const s = S.symbolOf[a.toLowerCase()] || short(a);
          const p = S.oracleData[s]?.price ?? 0n;
          return `<tr><td><b>${s}</b></td><td>${pct(weights[i])}</td><td>${fmtTok(held[i])}</td><td>${fmtUsd((held[i] * p) / 10n ** 18n)}</td></tr>`;
        }).join("")
      : '<tr><td colspan="4" class="muted">All cash (every holding was sold by Enforce)</td></tr>';

    // Rules vs. current exposure
    const exps = await Promise.all(rules.map((ru) => f.exposureOf(ru.theme)));
    $("ruleStatus").innerHTML = rules.map((ru, i) => {
      const theme = THEMES.find((t) => THEME_ID[t] === ru.theme) || "Theme";
      const e = Number(exps[i]);
      const min = Number(ru.minBps), max = Number(ru.maxBps), mt = Number(ru.maxTier);
      const ok = e >= min && e <= max;
      const worst = Math.max(0, ...assets.map((a) => tierOf(S.oracleData[S.symbolOf[a.toLowerCase()]]?.[theme === "AI" ? "ai" : "oil"] ?? 0)));
      const tierOk = worst <= mt;
      const limits = [min > 0 ? `≥ ${pct(min)}` : null, max < 10000 ? `≤ ${pct(max)}` : null].filter(Boolean).join(" and ");
      const tierRule = mt < 3 ? ` · no stock above ${TIER[mt]}` : "";
      return `<div><b>${theme}</b> ${pct(e)} <span class="muted">(rule: ${limits || "any"}${tierRule})</span> ` +
        `${ok && tierOk ? '<span class="tier t1">OK</span>' : '<span class="tier t3">BREACH</span>'}` +
        `<div class="bar"><span style="width:${Math.min(100, e / 100)}%;background:${ok && tierOk ? "var(--good)" : "var(--bad)"}"></span>` +
        (min > 0 ? `<i style="left:${min / 100}%"></i>` : "") + (max < 10000 ? `<i style="left:${max / 100}%"></i>` : "") + `</div></div>`;
    }).join("");

    if (resetEditor) {
      basketEditor("proposeBasket", "proposeSum", assets.map((a, i) => [S.symbolOf[a.toLowerCase()], Number(weights[i]) / 100]));
    }
  }

  async function deposit() {
    try {
      const amt = ethers.parseUnits(String($("depositAmt").value || "0"), 18);
      if (amt <= 0n) throw new Error("Enter an amount");
      const bal = await S.usd.balanceOf(S.account);
      if (bal < amt) throw new Error("Not enough test dollars. Click 'Get 10,000 test dollars' first.");
      const allowance = await S.usd.allowance(S.account, S.fund);
      if (allowance < amt) await send("Approve test dollars", S.usd, "approve", [S.fund, amt]);
      await send(`Deposit ${fmtUsd(amt, 0)}`, fundContract(), "deposit", [amt]);
      await refreshAll();
    } catch (e) {
      log("Deposit failed: " + decodeError(e), "bad");
    }
  }

  async function redeem() {
    try {
      const amt = ethers.parseUnits(String($("redeemAmt").value || "0"), 18);
      if (amt <= 0n) throw new Error("Enter how many tokens to cash out");
      await send(`Cash out ${fmtTok(amt)} $${S.fundInfo.sym}`, fundContract(), "redeem", [amt]);
      $("redeemAmt").value = "";
      await refreshAll();
    } catch (e) {
      log("Cash out failed: " + decodeError(e), "bad");
    }
  }

  function tryXom() {
    const { assets, weights } = S.fundInfo;
    const rows = assets.map((a, i) => [S.symbolOf[a.toLowerCase()], Math.round(Number(weights[i]) * 0.95) / 100]);
    const used = rows.reduce((x, [, w]) => x + Math.round(w * 100), 0);
    rows.push(["XOM", (10000 - used) / 100]);
    basketEditor("proposeBasket", "proposeSum", rows);
    checkPropose();
  }

  async function checkPropose() {
    try {
      const [a, w] = readBasket("proposeBasket");
      const [ok, why] = await fundContract().checkBasket(a, w);
      setResult("proposeResult", ok ? "✓ This basket passes every rule." : "✗ Would be rejected: " + why, ok, !ok);
    } catch (e) {
      setResult("proposeResult", "✗ " + decodeError(e), false);
    }
  }

  async function propose() {
    try {
      if (S.account?.toLowerCase() !== S.fundInfo.creator.toLowerCase()) throw new Error("Only the fund's creator can change its basket");
      const [a, w] = readBasket("proposeBasket");
      const receipt = await send("Propose basket change", fundContract(), "proposeBasket", [a, w]);
      const evs = receipt.logs.map((l) => { try { return FUND_IFACE.parseLog(l); } catch (_) { return null; } }).filter(Boolean);
      const fail = evs.find((x) => x.name === "CheckFailed");
      await refreshAll(true);
      if (fail) {
        setResult("proposeResult", `✗ REJECTED on-chain: ${fail.args.reason}`, false, true);
        log(`Basket change REJECTED on-chain: ${fail.args.reason} ${txLink(receipt.hash)}`, "bad");
      } else {
        setResult("proposeResult", "✓ Basket changed. All rules still pass.", true);
      }
    } catch (e) {
      setResult("proposeResult", "✗ " + decodeError(e), false);
    }
  }

  async function enforce() {
    try {
      const receipt = await send("Enforce rules", fundContract(), "enforce", []);
      const evs = receipt.logs.map((l) => { try { return FUND_IFACE.parseLog(l); } catch (_) { return null; } }).filter(Boolean);
      const sold = evs.filter((x) => x.name === "Enforced");
      await refreshAll(true);
      if (sold.length) {
        const msg = sold.map((x) => `sold ${S.symbolOf[x.args.asset.toLowerCase()]} (${x.args.reason}) for ${fmtUsd(x.args.usdSold)}, bounty ${fmtUsd(x.args.bounty)} paid to you`).join("; ");
        setResult("enforceResult", "⚡ Breach fixed: " + msg, true, true);
        log("Enforced: " + msg, "ok");
      } else {
        setResult("enforceResult", "✓ No breach found. Check recorded.", true);
      }
    } catch (e) {
      setResult("enforceResult", "✗ " + decodeError(e), false);
    }
  }

  // ------------------------------------------------------------ refresh

  async function refreshBalances() {
    if (!S.account) return;
    const r = S.browser || S.reader;
    const mon = await r.getBalance(S.account);
    const usd = S.usd ? await S.usd.balanceOf(S.account) : 0n;
    $("balances").textContent = `${Number(ethers.formatEther(mon)).toFixed(3)} MON · ${fmtUsd(usd, 0)} test`;
  }

  async function refreshAll(resetEditor = false) {
    try {
      await refreshBalances();
      if (!S.platformAddr || !S.oracle) return;
      await loadOracle();
      await loadFunds();
      if (S.fund) await loadFund(resetEditor);
    } catch (e) {
      log("Refresh failed: " + decodeError(e), "bad");
    }
  }

  function buildStaticUi() {
    $("driftStock").innerHTML = Object.keys(S.stocks).map((s) => `<option ${s === "MSFT" ? "selected" : ""}>${s}</option>`).join("");
    if (!$("launchBasket").children.length) {
      basketEditor("launchBasket", "launchSum", [["NVDA", 50], ["AMD", 20], ["MSFT", 20], ["GOOGL", 10]]);
    }
  }

  // ------------------------------------------------------------ wiring

  $("connectBtn").onclick = connect;
  $("deployBtn").onclick = deployPlatform;
  $("usePlatformBtn").onclick = async () => {
    const a = $("platformInput").value.trim();
    if (!ethers.isAddress(a)) { alert("That is not a valid address"); return; }
    savePlatform(a);
    try { await loadPlatform(); } catch (e) { log("Could not load platform: " + decodeError(e), "bad"); }
  };
  $("faucetBtn").onclick = async () => {
    try { await send("Get 10,000 test dollars", S.exchange, "faucet"); await refreshBalances(); } catch (e) { log("Faucet failed: " + decodeError(e), "bad"); }
  };
  $("fmpBtn").onclick = fetchFmp;
  $("postBtn").onclick = postOracle;
  $("driftBtn").onclick = postDrift;
  $("launchAddRow").onclick = () => addBasketRow("launchBasket", "launchSum", "AVGO", 0);
  $("proposeAddRow").onclick = () => addBasketRow("proposeBasket", "proposeSum", "AVGO", 0);
  $("previewLaunchBtn").onclick = previewLaunch;
  $("launchBtn").onclick = launch;
  $("depositBtn").onclick = deposit;
  $("redeemMaxBtn").onclick = () => { if (S.fundInfo) $("redeemAmt").value = ethers.formatUnits(S.fundInfo.mine, 18); };
  $("redeemBtn").onclick = redeem;
  $("tryXomBtn").onclick = tryXom;
  $("checkProposeBtn").onclick = checkPropose;
  $("proposeBtn").onclick = propose;
  $("enforceBtn").onclick = enforce;

  // Start: read-only view works without a wallet.
  (async () => {
    S.platformAddr = platformFromSources();
    if (S.platformAddr) {
      try { await loadPlatform(); } catch (e) {
        log("Could not load platform: " + decodeError(e), "bad");
        $("setupSection").classList.remove("hidden");
      }
    } else {
      $("setupSection").classList.remove("hidden");
    }
    if (window.ethereum) {
      const accts = await window.ethereum.request({ method: "eth_accounts" }).catch(() => []);
      if (accts.length) connect();
    }
  })();

  // Exposed for automated testing only.
  window.__mandate = { S, CHAIN, decodeError };
})();
