(() => {
  "use strict";

  const TRACE_URL = "https://www.cloudflare.com/cdn-cgi/trace";
  const METADATA_URL = "https://ipwho.is/?fields=ip,success,country,country_code,region,city,connection,timezone";
  const STUN_URL = "stun:stun.cloudflare.com:3478";
  const NETWORK_TIMEOUT_MS = 8000;
  const ICE_TIMEOUT_MS = 5500;
  const NETWORK_CACHE_MS = 60000;

  const elements = {
    summary: document.querySelector(".summary"),
    overallTitle: document.getElementById("overall-title"),
    overallDetail: document.getElementById("overall-detail"),
    continueButton: document.getElementById("continue-button"),
    retryButton: document.getElementById("retry-button"),
    riskAcceptance: document.getElementById("risk-acceptance"),
    riskAcceptanceCheckbox: document.getElementById("risk-acceptance-checkbox"),
    riskAcceptanceStatus: document.getElementById("risk-acceptance-status"),
    network: rowElements("network"),
    reputation: rowElements("reputation"),
    timezone: rowElements("timezone"),
    webrtc: rowElements("webrtc"),
    language: rowElements("language"),
    fingerprint: rowElements("fingerprint"),
  };

  let generation = 0;
  let fetchController = null;
  let peerConnection = null;
  let scheduledCheck = null;
  let networkCache = null;
  let acceptedRiskKey = null;
  let lastEvaluation = null;

  function rowElements(name) {
    return {
      row: document.getElementById(`${name}-row`),
      status: document.getElementById(`${name}-status`),
      detail: document.getElementById(`${name}-detail`),
    };
  }

  function setRow(target, state, label, detail) {
    target.row.dataset.state = state;
    target.status.textContent = label;
    target.detail.textContent = detail;
  }

  function setCheckingState() {
    elements.summary.dataset.state = "checking";
    elements.overallTitle.textContent = "正在檢查";
    elements.overallDetail.textContent = "請稍候完成所有必要檢查。";
    setRow(elements.network, "checking", "檢查中", "正在讀取出口資料…");
    setRow(elements.reputation, "checking", "檢查中", "正在確認可用的信譽資料…");
    setRow(elements.timezone, "checking", "檢查中", "正在比對出口與瀏覽器時區…");
    setRow(elements.webrtc, "checking", "檢查中", "正在觀察網絡候選位址…");
    setRow(elements.language, "checking", "檢查中", "正在比對出口與瀏覽器語言…");
    setRow(elements.fingerprint, "checking", "檢查中", "正在檢查瀏覽器環境…");
    elements.continueButton.disabled = true;
    elements.retryButton.disabled = true;
    elements.riskAcceptanceCheckbox.disabled = true;
  }

  function parseTrace(body) {
    const values = Object.create(null);
    for (const line of body.split(/\r?\n/)) {
      const separator = line.indexOf("=");
      if (separator <= 0) continue;
      const key = line.slice(0, separator).trim();
      if (!(key in values)) values[key] = line.slice(separator + 1).trim();
    }
    return values;
  }

  function normalizeIPv4(value) {
    const parts = value.split(".");
    if (parts.length !== 4 || parts.some((part) => !/^\d{1,3}$/.test(part))) return null;
    const numbers = parts.map(Number);
    if (numbers.some((part) => part < 0 || part > 255)) return null;
    return numbers.join(".");
  }

  function normalizeIPv6(value) {
    let address = value.toLowerCase();
    const zoneIndex = address.indexOf("%");
    if (zoneIndex !== -1) address = address.slice(0, zoneIndex);
    if (!address.includes(":")) return null;

    const doubleColon = address.indexOf("::");
    if (doubleColon !== -1 && doubleColon !== address.lastIndexOf("::")) return null;
    let left = doubleColon === -1 ? address.split(":") : address.slice(0, doubleColon).split(":").filter(Boolean);
    let right = doubleColon === -1 ? [] : address.slice(doubleColon + 2).split(":").filter(Boolean);

    function expandIPv4Tail(parts) {
      if (parts.length === 0 || !parts[parts.length - 1].includes(".")) return parts;
      const ipv4 = normalizeIPv4(parts.pop());
      if (!ipv4) return null;
      const bytes = ipv4.split(".").map(Number);
      parts.push(((bytes[0] << 8) | bytes[1]).toString(16));
      parts.push(((bytes[2] << 8) | bytes[3]).toString(16));
      return parts;
    }

    left = expandIPv4Tail(left);
    right = expandIPv4Tail(right);
    if (!left || !right) return null;
    const missing = 8 - left.length - right.length;
    if ((doubleColon === -1 && missing !== 0) || (doubleColon !== -1 && missing < 1)) return null;
    const groups = [...left, ...Array(missing).fill("0"), ...right];
    if (groups.length !== 8 || groups.some((group) => !/^[0-9a-f]{1,4}$/.test(group))) return null;
    return groups.map((group) => group.padStart(4, "0")).join(":");
  }

  function normalizeIP(value) {
    if (typeof value !== "string") return null;
    const trimmed = value.trim().replace(/^\[|\]$/g, "");
    return normalizeIPv4(trimmed) || normalizeIPv6(trimmed);
  }

  function isPublicIP(value) {
    const normalized = normalizeIP(value);
    if (!normalized) return false;
    if (normalized.includes(".")) {
      const [a, b, c] = normalized.split(".").map(Number);
      if (a === 0 || a === 10 || a === 127 || a >= 224) return false;
      if (a === 100 && b >= 64 && b <= 127) return false;
      if (a === 169 && b === 254) return false;
      if (a === 172 && b >= 16 && b <= 31) return false;
      if (a === 192 && b === 168) return false;
      if (a === 192 && b === 0 && (c === 0 || c === 2)) return false;
      if (a === 198 && (b === 18 || b === 19)) return false;
      if (a === 198 && b === 51 && c === 100) return false;
      if (a === 203 && b === 0 && c === 113) return false;
      return true;
    }

    const groups = normalized.split(":").map((part) => Number.parseInt(part, 16));
    if (groups.every((part) => part === 0)) return false;
    if (groups.slice(0, 7).every((part) => part === 0) && groups[7] === 1) return false;
    if ((groups[0] & 0xfe00) === 0xfc00) return false;
    if ((groups[0] & 0xffc0) === 0xfe80) return false;
    if ((groups[0] & 0xff00) === 0xff00) return false;
    if (groups[0] === 0x2001 && groups[1] === 0x0db8) return false;
    return true;
  }

  function canonicalTimeZone(value) {
    if (typeof value !== "string" || !value.trim()) return "";
    try {
      return new Intl.DateTimeFormat("en", { timeZone: value.trim() }).resolvedOptions().timeZone || "";
    } catch (_) {
      return "";
    }
  }

  function expectedEnvironment() {
    const params = new URLSearchParams(window.location.hash.slice(1));
    const timezone = canonicalTimeZone(params.get("timezone") || "");
    let assessment = null;
    try {
      const encoded = params.get("assessment") || "";
      if (encoded && encoded.length <= 8192 && /^[A-Za-z0-9_-]+$/.test(encoded)) {
        const base64 = encoded.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(encoded.length / 4) * 4, "=");
        const bytes = Uint8Array.from(atob(base64), (character) => character.charCodeAt(0));
        const parsed = JSON.parse(new TextDecoder().decode(bytes));
        if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) assessment = parsed;
      }
    } catch (_) {
      return { timezone: "", assessment: null };
    }
    return { timezone, assessment };
  }

  function supportedRegions() {
    const source = typeof CLAUDE_SUPPORTED_REGIONS === "undefined" ? null : CLAUDE_SUPPORTED_REGIONS;
    if (source instanceof Set) return source;
    if (Array.isArray(source)) return new Set(source);
    return null;
  }

  function unsupportedSubdivision(countryCode, region) {
    if (countryCode !== "UA") return false;
    if (typeof region !== "string" || !region.trim()) return null;
    const exclusions = typeof CLAUDE_UKRAINE_UNSUPPORTED_REGIONS === "undefined"
      ? null
      : CLAUDE_UKRAINE_UNSUPPORTED_REGIONS;
    if (!Array.isArray(exclusions)) return null;
    const normalized = region.trim().toLocaleLowerCase("en-US");
    return exclusions.some((value) => normalized.includes(value.toLocaleLowerCase("en-US")));
  }

  async function fetchText(url, signal) {
    const response = await fetch(url, {
      cache: "no-store",
      credentials: "omit",
      referrerPolicy: "no-referrer",
      signal,
    });
    if (!response.ok) throw new Error("response");
    return response.text();
  }

  async function fetchJSON(url, signal) {
    const response = await fetch(url, {
      cache: "no-store",
      credentials: "omit",
      referrerPolicy: "no-referrer",
      signal,
    });
    if (!response.ok) throw new Error("response");
    return response.json();
  }

  function networkDescription(countryCode, ip, metadata) {
    const connection = metadata.connection && typeof metadata.connection === "object" ? metadata.connection : {};
    const asnValue = connection.asn;
    const asn = typeof asnValue === "number" || /^AS?\d+$/i.test(String(asnValue || ""))
      ? `AS${String(asnValue).replace(/^AS/i, "")}`
      : "";
    const organization = typeof connection.org === "string" ? connection.org.trim() : "";
    return [countryCode, ip, asn, organization].filter(Boolean).join("・");
  }

  async function readNetwork(signal) {
    const [traceBody, metadata] = await Promise.all([
      fetchText(TRACE_URL, signal),
      fetchJSON(METADATA_URL, signal),
    ]);
    return { trace: parseTrace(traceBody), metadata };
  }

  async function checkNetwork(signal, forceFresh = false) {
    if (navigator.onLine === false) {
      return { state: "fail", detail: "目前沒有網絡連線", ip: null, timezone: "", offset: null };
    }

    const expected = expectedEnvironment();
    const expectedIP = normalizeIP(expected.assessment?.ip || "");
    const expectedCountry = typeof expected.assessment?.exitCountryCode === "string"
      ? expected.assessment.exitCountryCode
      : "";
    if (expected.assessment?.schema !== 1 || !expectedIP || !expected.timezone || !/^[A-Z]{2}$/.test(expectedCountry)) {
      return { state: "unknown", detail: "啟動資料不完整，請重新開啟 Claude Chrome", ip: null, timezone: "", offset: null };
    }

    let payload;
    const now = Date.now();
    if (!forceFresh && networkCache && now - networkCache.createdAt < NETWORK_CACHE_MS) {
      payload = networkCache.payload;
    } else {
      try {
        payload = await readNetwork(signal);
        networkCache = { createdAt: now, payload };
      } catch (_) {
        return { state: "unknown", detail: "無法讀取出口資料", ip: null, timezone: "", offset: null };
      }
    }

    const { trace, metadata } = payload;
    if (!metadata || typeof metadata !== "object" || metadata.success !== true) {
      return { state: "unknown", detail: "出口資料格式無法辨識", ip: null, timezone: "", offset: null };
    }

    const traceIP = normalizeIP(trace.ip || "");
    const metadataIP = normalizeIP(metadata.ip || "");
    const traceCountry = /^[A-Za-z]{2}$/.test(trace.loc || "") ? trace.loc.toUpperCase() : "";
    const metadataCountry = /^[A-Za-z]{2}$/.test(metadata.country_code || "") ? metadata.country_code.toUpperCase() : "";
    const timezone = canonicalTimeZone(metadata.timezone && typeof metadata.timezone === "object" ? metadata.timezone.id : "");
    const offset = metadata.timezone && typeof metadata.timezone === "object" ? metadata.timezone.offset : null;
    if (!traceIP || !metadataIP || !isPublicIP(traceIP) || !isPublicIP(metadataIP) || !traceCountry || !metadataCountry || !timezone || !Number.isInteger(offset)) {
      return { state: "unknown", detail: "出口資料不完整", ip: null, timezone: "", offset: null };
    }
    if (traceIP !== metadataIP || traceCountry !== metadataCountry) {
      return { state: "fail", detail: "兩個出口來源的結果不一致", ip: traceIP, timezone, offset };
    }
    if (traceIP !== expectedIP || traceCountry !== expectedCountry || timezone !== expected.timezone) {
      return { state: "fail", detail: "出口地區、IP 或時區已改變，請重新開啟 Claude Chrome", ip: traceIP, country: traceCountry, timezone, offset };
    }

    const regions = supportedRegions();
    if (!regions) {
      return { state: "unknown", detail: "無法讀取支援地區清單", ip: traceIP, timezone, offset };
    }
    const excludedSubdivision = unsupportedSubdivision(traceCountry, metadata.region);
    if (excludedSubdivision === null) {
      return { state: "unknown", detail: "無法確認此出口的地區範圍", ip: traceIP, country: traceCountry, timezone, offset };
    }
    const supported = regions.has(traceCountry) && excludedSubdivision === false;
    return {
      state: supported ? "pass" : "fail",
      ip: traceIP,
      country: traceCountry,
      timezone,
      offset,
      detail: supported
        ? `${networkDescription(traceCountry, traceIP, metadata)}・地區受支援`
        : `${networkDescription(traceCountry, traceIP, metadata)}・地區不在支援清單`,
    };
  }

  function workerClockProbe() {
    return new Promise((resolve) => {
      const source = "self.onmessage=()=>{try{const d=new Date();self.postMessage({timezone:Intl.DateTimeFormat().resolvedOptions().timeZone||'',offset:-d.getTimezoneOffset()*60})}catch(e){self.postMessage(null)}}";
      let blobURL = "";
      let worker = null;
      let timer = null;
      let settled = false;
      const finish = (value) => {
        if (settled) return;
        settled = true;
        if (timer !== null) clearTimeout(timer);
        if (worker) worker.terminate();
        if (blobURL) URL.revokeObjectURL(blobURL);
        resolve(value);
      };
      try {
        blobURL = URL.createObjectURL(new Blob([source], { type: "text/javascript" }));
        worker = new Worker(blobURL);
      } catch (_) {
        finish(null);
        return;
      }
      timer = setTimeout(() => finish(null), 2500);
      worker.onmessage = (event) => finish(event.data);
      worker.onerror = () => finish(null);
      try {
        worker.postMessage(null);
      } catch (_) {
        finish(null);
      }
    });
  }

  async function checkTimezone(expectedZone, expectedOffset) {
    if (!expectedZone || !Number.isInteger(expectedOffset)) {
      return { state: "unknown", detail: "需先取得出口時區" };
    }
    try {
      const now = new Date();
      const main = {
        timezone: canonicalTimeZone(Intl.DateTimeFormat().resolvedOptions().timeZone || ""),
        offset: -now.getTimezoneOffset() * 60,
      };
      const worker = await workerClockProbe();
      if (!worker || typeof worker.timezone !== "string" || !Number.isInteger(worker.offset)) {
        return { state: "unknown", detail: "無法讀取背景頁時區" };
      }
      const workerTimeZone = canonicalTimeZone(worker.timezone);
      const matches = main.timezone === expectedZone
        && workerTimeZone === expectedZone
        && main.offset === expectedOffset
        && worker.offset === expectedOffset;
      return {
        state: matches ? "pass" : "fail",
        detail: matches
          ? `${expectedZone}・主頁與背景頁一致`
          : `出口 ${expectedZone}・主頁 ${main.timezone || "未知"}・背景頁 ${workerTimeZone || "未知"}`,
      };
    } catch (_) {
      return { state: "unknown", detail: "無法比對出口與瀏覽器時區" };
    }
  }

  function checkReputation(network) {
    const assessment = expectedEnvironment().assessment;
    if (!assessment || assessment.schema !== 1) {
      return { state: "unknown", detail: "IP 信譽資料格式無法辨識" };
    }
    if (assessment.status === "unknown") {
      return { state: "unknown", detail: "IP 信譽未驗證；請重新開啟 Claude Chrome" };
    }
    if (assessment.status !== "ok" && assessment.status !== "warning") {
      return { state: "unknown", detail: "IP 信譽資料格式無法辨識" };
    }

    const detections = assessment.detections;
    const booleanKeys = ["hosting", "proxy", "vpn", "tor", "compromised", "scraper", "anonymous"];
    const booleansValid = detections
      && typeof detections === "object"
      && booleanKeys.every((key) => typeof detections[key] === "boolean");
    const scoresValid = detections
      && typeof detections.risk === "number"
      && Number.isFinite(detections.risk)
      && detections.risk >= 0
      && detections.risk <= 100
      && typeof detections.confidence === "number"
      && Number.isFinite(detections.confidence)
      && detections.confidence >= 0
      && detections.confidence <= 100;
    const checkedAtValid = Number.isInteger(assessment.checkedAt)
      && assessment.checkedAt <= Date.now()
      && Date.now() - assessment.checkedAt <= 30 * 60 * 1000;
    const countryCode = typeof assessment.countryCode === "string" ? assessment.countryCode.toUpperCase() : "";
    const timeZone = canonicalTimeZone(assessment.timeZone);
    const networkTypeValid = typeof assessment.networkType === "string" && assessment.networkType.trim().length > 0;
    const providerValid = typeof assessment.provider === "string" && assessment.provider.trim().length > 0;
    if (!booleansValid || !scoresValid || !checkedAtValid || !/^[A-Z]{2}$/.test(countryCode) || !timeZone || !networkTypeValid || !providerValid) {
      return { state: "unknown", detail: "IP 信譽資料不完整或已過期；請重新開啟 Claude Chrome" };
    }

    const assessmentIP = normalizeIP(assessment.ip || "");
    if (!assessmentIP || assessmentIP !== network.ip || countryCode !== network.country || timeZone !== network.timezone) {
      return { state: "fail", detail: "出口與信譽資料不一致；請重新開啟 Claude Chrome" };
    }

    const detectionLabels = {
      hosting: "機房出口",
      proxy: "代理",
      vpn: "VPN",
      tor: "Tor",
      compromised: "疑似受侵害",
      scraper: "自動抓取",
      anonymous: "匿名網絡",
    };
    const detected = booleanKeys.filter((key) => detections[key] === true);
    const acceptable = detected.length === 0 && detections.risk <= 25;
    const overrideEligible = detections.hosting === true
      && booleanKeys.filter((key) => key !== "hosting").every((key) => detections[key] === false);
    const snapshotKey = JSON.stringify({
      schema: assessment.schema,
      ip: assessmentIP,
      countryCode,
      timeZone,
      checkedAt: assessment.checkedAt,
      networkType: assessment.networkType,
      provider: assessment.provider,
      detections: booleanKeys.reduce((values, key) => {
        values[key] = detections[key];
        return values;
      }, { risk: detections.risk, confidence: detections.confidence }),
    });
    const failureReason = detected.length > 0
      ? detected.map((key) => detectionLabels[key]).join("、")
      : "超出保守門檻";
    return {
      state: acceptable ? "pass" : "fail",
      overrideEligible: !acceptable && overrideEligible,
      snapshotKey,
      detail: acceptable
        ? `未觀察到所列風險・ProxyCheck 風險值 ${detections.risk}/100`
        : `${failureReason}・ProxyCheck 風險值 ${detections.risk}/100`,
    };
  }

  function expectedLanguages(network) {
    const assessment = expectedEnvironment().assessment;
    if (!assessment || assessment.schema !== 1) {
      return { state: "unknown", detail: "啟動語言資料格式無法辨識" };
    }

    const country = assessment.exitCountryCode;
    const primary = assessment.exitLanguage;
    const languages = assessment.exitLanguages;
    if (typeof country !== "string" || !/^[A-Z]{2}$/.test(country)
      || typeof primary !== "string" || !Array.isArray(languages)) {
      return { state: "unknown", detail: "啟動語言資料不完整" };
    }
    if (country !== network.country) {
      return { state: "fail", detail: "出口地區已改變，請重新開啟 Claude Chrome" };
    }

    try {
      const canonical = Intl.getCanonicalLocales(primary);
      if (canonical.length !== 1 || canonical[0] !== primary) {
        return { state: "fail", detail: "啟動語言標籤格式不一致" };
      }
      const locale = new Intl.Locale(primary);
      const baseParts = [locale.language, locale.script].filter(Boolean);
      const expectedBaseName = [...baseParts, locale.region].filter(Boolean).join("-");
      const fallback = Intl.getCanonicalLocales(baseParts.join("-"))[0];
      if (locale.region !== country || locale.baseName !== expectedBaseName || primary !== locale.baseName) {
        return { state: "fail", detail: "啟動語言與出口地區不一致" };
      }
      if (languages.length !== 2 || languages[0] !== primary || languages[1] !== fallback) {
        return { state: "fail", detail: "啟動語言順序不一致" };
      }
      return { state: "pass", primary, languages, detail: `${primary}・${languages.join("、")}` };
    } catch (_) {
      return { state: "unknown", detail: "無法辨識啟動語言標籤" };
    }
  }

  function checkLanguage(network) {
    const expected = expectedLanguages(network);
    if (expected.state !== "pass") return expected;

    const primary = typeof navigator.language === "string" ? navigator.language : "";
    const languages = Array.isArray(navigator.languages) ? Array.from(navigator.languages) : null;
    if (!primary || !languages || languages.some((value) => typeof value !== "string")) {
      return { state: "unknown", detail: "瀏覽器未提供完整語言資料" };
    }
    const matches = primary === expected.primary
      && languages.length === expected.languages.length
      && languages.every((value, index) => value === expected.languages[index]);
    return {
      state: matches ? "pass" : "fail",
      detail: matches
        ? `${primary}・與 ${network.country} 出口一致`
        : `瀏覽器 ${languages.join("、") || primary}・預期 ${expected.languages.join("、")}`,
    };
  }

  function parseCandidate(candidate) {
    const parts = String(candidate.candidate || "").trim().split(/\s+/);
    const typeIndex = parts.indexOf("typ");
    return {
      address: candidate.address || parts[4] || "",
      protocol: String(candidate.protocol || parts[2] || "").toLowerCase(),
      type: String(candidate.type || (typeIndex >= 0 ? parts[typeIndex + 1] : "")).toLowerCase(),
    };
  }

  async function gatherCandidates(token) {
    if (typeof RTCPeerConnection !== "function") {
      return { complete: false, candidates: [], reason: "此瀏覽器不支援 WebRTC 檢查" };
    }

    let connection;
    try {
      connection = new RTCPeerConnection({ iceServers: [{ urls: STUN_URL }], iceCandidatePoolSize: 0 });
    } catch (_) {
      return { complete: false, candidates: [], reason: "無法啟動 WebRTC 檢查" };
    }
    peerConnection = connection;
    const candidates = [];

    try {
      connection.createDataChannel("environment-check");
      const complete = await new Promise((resolve) => {
        let settled = false;
        const finish = (result) => {
          if (settled) return;
          settled = true;
          resolve(result);
        };
        const timer = setTimeout(() => finish(false), ICE_TIMEOUT_MS);
        connection.onicecandidate = (event) => {
          if (event.candidate) candidates.push(parseCandidate(event.candidate));
        };
        connection.onicegatheringstatechange = () => {
          if (connection.iceGatheringState === "complete") {
            clearTimeout(timer);
            finish(true);
          }
        };
        connection.createOffer()
          .then((offer) => connection.setLocalDescription(offer))
          .then(() => {
            if (connection.iceGatheringState === "complete") {
              clearTimeout(timer);
              finish(true);
            }
          })
          .catch(() => {
            clearTimeout(timer);
            finish(false);
          });
      });
      if (token !== generation) return { complete: false, candidates: [], reason: "檢查已更新" };
      return { complete, candidates, reason: complete ? "" : "WebRTC 檢查逾時或未完成" };
    } catch (_) {
      return { complete: false, candidates: [], reason: "無法完成 WebRTC 檢查" };
    } finally {
      try {
        connection.close();
      } catch (_) {
        // The result remains unknown if the connection failed before gathering.
      }
      if (peerConnection === connection) peerConnection = null;
    }
  }

  function evaluateWebRTC(gathered, observedIP) {
    if (!gathered.complete) return { state: "unknown", detail: gathered.reason || "WebRTC 狀態未知" };

    const observed = normalizeIP(observedIP);
    for (const candidate of gathered.candidates) {
      if (candidate.type === "relay") continue;
      if (candidate.address.toLowerCase().endsWith(".local")) continue;
      const normalized = normalizeIP(candidate.address);
      if (!normalized) continue;
      if (!isPublicIP(normalized)) return { state: "fail", detail: "觀察到本機或私人 WebRTC 位址" };
      if (candidate.protocol === "udp") {
        return { state: "fail", detail: "觀察到未經代理的 WebRTC UDP 位址" };
      }
      if (normalized !== observed) return { state: "fail", detail: "WebRTC 公網位址與 HTTPS 出口不一致" };
    }
    return { state: "pass", detail: "未觀察到非代理 UDP 或額外公網 IP" };
  }

  function canvasSample() {
    const canvas = document.createElement("canvas");
    canvas.width = 240;
    canvas.height = 72;
    const context = canvas.getContext("2d");
    if (!context) return null;
    context.fillStyle = "#f7f0e5";
    context.fillRect(0, 0, canvas.width, canvas.height);
    context.fillStyle = "#c76545";
    context.fillRect(13, 11, 67, 39);
    context.fillStyle = "#332823";
    context.font = "17px -apple-system, sans-serif";
    context.fillText("Claude 環境 Aa 28", 25, 59);
    return canvas.toDataURL("image/png");
  }

  function localDigest(value) {
    let hash = 0x811c9dc5;
    for (let index = 0; index < value.length; index += 1) {
      hash ^= value.charCodeAt(index);
      hash = Math.imul(hash, 0x01000193);
    }
    return (hash >>> 0).toString(16).padStart(8, "0").toUpperCase();
  }

  function webGLRenderer() {
    const canvas = document.createElement("canvas");
    const context = canvas.getContext("webgl") || canvas.getContext("experimental-webgl");
    if (!context) return "";
    const extension = context.getExtension("WEBGL_debug_renderer_info");
    const value = extension ? context.getParameter(extension.UNMASKED_RENDERER_WEBGL) : context.getParameter(context.RENDERER);
    return typeof value === "string" ? value.trim() : "";
  }

  function checkFingerprint() {
    try {
      if (navigator.webdriver !== false) return { state: "fail", detail: "瀏覽器顯示自動化狀態" };
      const userAgent = navigator.userAgent || "";
      const platform = navigator.userAgentData?.platform || navigator.platform || "";
      if (!/Chrome\/\d+/.test(userAgent) || !/Macintosh/.test(userAgent) || !/mac/i.test(platform)) {
        return { state: "fail", detail: "瀏覽器識別與 macOS Chrome 不一致" };
      }
      if (!Number.isInteger(navigator.hardwareConcurrency) || navigator.hardwareConcurrency < 1 || navigator.hardwareConcurrency > 256) {
        return { state: "fail", detail: "處理器資訊超出合理範圍" };
      }
      if (screen.width < 800 || screen.height < 600 || screen.width > 16384 || screen.height > 16384) {
        return { state: "fail", detail: "畫面尺寸超出合理範圍" };
      }

      const firstCanvas = canvasSample();
      const secondCanvas = canvasSample();
      const renderer = webGLRenderer();
      if (!firstCanvas || !secondCanvas || !renderer) return { state: "unknown", detail: "無法完成本機圖形一致性檢查" };
      if (firstCanvas !== secondCanvas) return { state: "fail", detail: "同一次檢查的 Canvas 結果不一致" };

      const rendererLabel = renderer.length > 64 ? `${renderer.slice(0, 61)}…` : renderer;
      return { state: "pass", detail: `本機摘要 ${localDigest(firstCanvas)}・${rendererLabel}` };
    } catch (_) {
      return { state: "unknown", detail: "無法完成瀏覽器一致性檢查" };
    }
  }

  function renderResult(target, result) {
    const label = result.state === "pass" ? "通過" : result.state === "fail" ? "未通過" : "未知";
    setRow(target, result.state, label, result.detail);
  }

  function configureRiskAcceptance(reputation) {
    if (reputation.overrideEligible !== true || typeof reputation.snapshotKey !== "string") {
      acceptedRiskKey = null;
      elements.riskAcceptance.hidden = true;
      elements.riskAcceptanceCheckbox.checked = false;
      elements.riskAcceptanceCheckbox.disabled = true;
      elements.riskAcceptanceStatus.textContent = "";
      return false;
    }

    if (acceptedRiskKey !== reputation.snapshotKey) {
      acceptedRiskKey = null;
      elements.riskAcceptanceCheckbox.checked = false;
    }
    elements.riskAcceptance.hidden = false;
    elements.riskAcceptanceCheckbox.disabled = false;
    const accepted = elements.riskAcceptanceCheckbox.checked
      && acceptedRiskKey === reputation.snapshotKey;
    elements.riskAcceptanceStatus.textContent = accepted ? "已接受目前機房 IP 風險" : "";
    return accepted;
  }

  function updateOverall(evaluation, navigate = false) {
    const { network, reputation, timezone, webrtc, language, fingerprint, token } = evaluation;
    const riskAccepted = configureRiskAcceptance(reputation);
    const required = [network, timezone, webrtc, language, fingerprint];
    const reputationPassed = reputation.state === "pass" || riskAccepted;
    const passed = reputationPassed && required.every((result) => result.state === "pass");
    const unknown = reputation.state === "unknown" || required.some((result) => result.state === "unknown");
    elements.summary.dataset.state = passed ? "pass" : unknown ? "unknown" : "fail";
    elements.overallTitle.textContent = passed ? "環境檢查通過" : unknown ? "仍有狀態無法確認" : "環境檢查未通過";
    elements.overallDetail.textContent = passed
      ? riskAccepted ? "已接受目前機房 IP 風險；其餘檢查通過。" : "目前可觀察條件符合設定。"
      : reputation.overrideEligible === true && !riskAccepted
        ? "請確認目前機房 IP 風險後再繼續。"
        : "請修正或重新檢查後再繼續。";
    elements.continueButton.disabled = !passed;
    elements.retryButton.disabled = false;

    if (passed && navigate && token === generation) window.location.assign("https://claude.ai");
    return passed;
  }

  async function runChecks(options = {}) {
    const token = ++generation;
    if (fetchController) fetchController.abort();
    if (peerConnection) peerConnection.close();
    const controller = new AbortController();
    fetchController = controller;
    const timeout = setTimeout(() => controller.abort(), NETWORK_TIMEOUT_MS);
    setCheckingState();

    let network;
    let gathered;
    let fingerprint;
    try {
      [network, gathered, fingerprint] = await Promise.all([
        checkNetwork(controller.signal, options.forceNetwork === true)
          .catch(() => ({ state: "unknown", detail: "無法完成出口檢查", ip: null, timezone: "", offset: null })),
        gatherCandidates(token)
          .catch(() => ({ complete: false, candidates: [], reason: "無法完成 WebRTC 檢查" })),
        Promise.resolve(checkFingerprint()),
      ]);
    } finally {
      clearTimeout(timeout);
      if (fetchController === controller) fetchController = null;
    }

    if (token !== generation) return false;
    const timezone = await checkTimezone(network.timezone, network.offset);
    if (token !== generation) return false;
    const reputation = checkReputation(network);
    const language = checkLanguage(network);
    const webrtc = network.ip ? evaluateWebRTC(gathered, network.ip) : { state: "unknown", detail: "需先確認 HTTPS 出口" };

    renderResult(elements.network, network);
    renderResult(elements.reputation, reputation);
    renderResult(elements.timezone, timezone);
    renderResult(elements.webrtc, webrtc);
    renderResult(elements.language, language);
    renderResult(elements.fingerprint, fingerprint);

    lastEvaluation = { network, reputation, timezone, webrtc, language, fingerprint, token };
    return updateOverall(lastEvaluation, options.navigate === true);
  }

  function scheduleCheck(delay = 180) {
    clearTimeout(scheduledCheck);
    scheduledCheck = setTimeout(() => runChecks(), delay);
  }

  elements.retryButton.addEventListener("click", () => runChecks({ forceNetwork: true }));
  elements.continueButton.addEventListener("click", () => runChecks({ navigate: true, forceNetwork: true }));
  elements.riskAcceptanceCheckbox.addEventListener("change", () => {
    const reputation = lastEvaluation?.reputation;
    if (!reputation || reputation.overrideEligible !== true || typeof reputation.snapshotKey !== "string") {
      acceptedRiskKey = null;
      elements.riskAcceptanceCheckbox.checked = false;
      return;
    }
    acceptedRiskKey = elements.riskAcceptanceCheckbox.checked ? reputation.snapshotKey : null;
    updateOverall(lastEvaluation);
  });
  window.addEventListener("focus", () => scheduleCheck());
  window.addEventListener("online", () => scheduleCheck(0));
  window.addEventListener("offline", () => scheduleCheck(0));
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") scheduleCheck();
  });
  setInterval(() => {
    if (document.visibilityState === "visible") runChecks();
  }, NETWORK_CACHE_MS);
  runChecks();
})();
