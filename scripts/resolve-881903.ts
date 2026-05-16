type Station = "881" | "903" | "864";

type ResolveOutput = {
  station: Station;
  stationKey: string;
  channel: number | null;
  generatedAt: string;
  pageUrl: string;
  bootstrapUrl: string;
  cfplaylistUrl: string;
  hlsUrl: string;
  cookies: Record<string, string>;
};

const stationMap: Record<Station, string> = {
  "881": "881hd",
  "903": "903hd",
  "864": "864sd"
};

const browserHeaders = {
  "User-Agent":
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome Safari/537.36",
  "Referer": "https://www.881903.com/",
  "Accept": "*/*"
};

function fail(message: string): never {
  throw new Error(message);
}

function assertStation(value: string | undefined): asserts value is Station {
  if (value !== "881" && value !== "903" && value !== "864") {
    fail("Usage: bun run resolve <881|903|864>");
  }
}

function atobUtf8(value: string): string {
  return Buffer.from(value, "base64").toString("utf8");
}

function atobBinary(value: string): string {
  return Buffer.from(value, "base64").toString("binary");
}

function randomAlphaNum(length: number): string {
  const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
  const bytes = new Uint8Array(length);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (byte) => alphabet[byte % alphabet.length]).join("");
}

function extractRetrieveKeys(html: string): [string, string] {
  const match = html.match(
    /return\s+atob\s*\(\s*d\.([A-Za-z0-9_$]+)\s*\+\s*d\.([A-Za-z0-9_$]+)\s*\)/
  );

  if (!match) {
    fail("Cannot find retrievePlaybackLink keys");
  }

  return [match[1], match[2]];
}

function extractVueAppScript(html: string): string {
  const scripts = Array.from(html.matchAll(/<script>([\s\S]*?)<\/script>/gi), (match) => match[1]);
  const script = scripts.find((candidate) => candidate.includes("VueApp.main"));

  if (!script) {
    fail("Cannot extract VueApp.main payload");
  }

  return script;
}

function extractInitData(script: string): Record<string, unknown> {
  let initData: Record<string, unknown> | null = null;

  const context = {
    document: {
      readyState: "complete",
      addEventListener() {}
    },
    VueApp: {
      main(value: Record<string, unknown>) {
        initData = value;
      }
    },
    atob: atobBinary,
    console
  };

  const vm = require("node:vm") as typeof import("node:vm");
  vm.runInNewContext(script, context, { timeout: 5000 });

  if (!initData) {
    fail("VueApp.main payload did not execute");
  }

  return initData;
}

function getSetCookies(headers: Headers): string[] {
  const headersWithCookies = headers as Headers & { getSetCookie?: () => string[] };

  if (typeof headersWithCookies.getSetCookie === "function") {
    const cookies = headersWithCookies.getSetCookie();
    if (cookies.length > 0) {
      return cookies;
    }
  }

  const raw = headers.get("set-cookie");
  if (!raw) {
    return [];
  }

  return raw.split(/,\s*(?=CloudFront-)/);
}

function parseCloudFrontCookies(setCookies: string[]): Record<string, string> {
  const wanted = new Set(["CloudFront-Policy", "CloudFront-Signature", "CloudFront-Key-Pair-Id"]);
  const cookies: Record<string, string> = {};

  for (const line of setCookies) {
    const [pair] = line.split(";");
    const [name, ...valueParts] = pair.split("=");

    if (wanted.has(name)) {
      cookies[name] = valueParts.join("=");
    }
  }

  for (const name of wanted) {
    if (!cookies[name]) {
      fail(`Missing ${name} signed cookie`);
    }
  }

  return cookies;
}

function findBalancedCall(source: string, startIndex: number): string {
  const openIndex = source.indexOf("(", startIndex);
  if (openIndex === -1) {
    fail("Cannot find VueApp.main call");
  }

  let depth = 0;
  let inString: string | null = null;
  let escaped = false;

  for (let index = openIndex; index < source.length; index += 1) {
    const char = source[index];

    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (char === "\\") {
        escaped = true;
      } else if (char === inString) {
        inString = null;
      }
      continue;
    }

    if (char === "\"" || char === "'" || char === "`") {
      inString = char;
      continue;
    }

    if (char === "(") {
      depth += 1;
    } else if (char === ")") {
      depth -= 1;
      if (depth === 0) {
        return source.slice(openIndex + 1, index);
      }
    }
  }

  fail("Cannot find end of VueApp.main call");
}

function extractInitDataWithoutDom(script: string): Record<string, unknown> {
  const callIndex = script.indexOf("VueApp.main");
  if (callIndex === -1) {
    fail("Cannot find VueApp.main payload");
  }

  const payloadExpression = findBalancedCall(script, callIndex);
  const vm = require("node:vm") as typeof import("node:vm");
  return vm.runInNewContext(`(${payloadExpression})`, { atob: atobBinary }, { timeout: 5000 });
}

function extractAtob2Block(bundle: string): string {
  const atob2Index = bundle.indexOf("window.atob2=function");
  if (atob2Index === -1) {
    fail("Cannot find window.atob2 decoder in live bundle");
  }

  const start = bundle.lastIndexOf("(function(){const e=[", atob2Index);
  const end = bundle.indexOf("})()},me=", atob2Index);

  if (start === -1 || end === -1) {
    fail("Cannot extract window.atob2 decoder block");
  }

  return bundle.slice(start, end + 4);
}

async function fetchText(url: string, init?: RequestInit): Promise<string> {
  const response = await fetch(url, init);

  if (!response.ok) {
    fail(`Fetch failed ${response.status} ${response.statusText}: ${url}`);
  }

  return response.text();
}

async function installAtob2(): Promise<(value: string) => string> {
  const appHtml = await fetchText("https://www.881903.com/live/881", { headers: browserHeaders });
  const liveBundleMatch = appHtml.match(/<script src="([^"]*\/static\/js\/live\.[^"]+\.js)"[^>]*>/);

  let bundleUrl: string;

  if (liveBundleMatch) {
    bundleUrl = new URL(liveBundleMatch[1], "https://www.881903.com").toString();
  } else {
    const appBundleMatch = appHtml.match(/<script src="([^"]*\/static\/js\/app\.[^"]+\.js)"[^>]*>/);
    if (!appBundleMatch) {
      fail("Cannot find app bundle script");
    }

    const appBundleUrl = new URL(appBundleMatch[1], "https://www.881903.com").toString();
    const appBundle = await fetchText(appBundleUrl, { headers: browserHeaders });

    const liveChunkIdMatch = appBundle.match(/(?:^|[,{])([0-9]+):"live"/);
    if (!liveChunkIdMatch) {
      fail("Cannot find live bundle chunk id");
    }

    const liveChunkId = liveChunkIdMatch[1];
    const hashMatch = Array.from(appBundle.matchAll(new RegExp(`${liveChunkId}:"([A-Za-z0-9]+)"`, "g")))
      .map((match) => match[1])
      .find((value) => /^[a-f0-9]{8}$/i.test(value));

    if (!hashMatch) {
      fail("Cannot find live bundle path");
    }

    bundleUrl = new URL(`/static/js/live.${hashMatch}.js`, "https://www.881903.com").toString();
  }

  const liveBundle = await fetchText(bundleUrl, { headers: browserHeaders });
  const atob2Block = extractAtob2Block(liveBundle);
  const vm = require("node:vm") as typeof import("node:vm");
  const context = {
    window: {} as { atob2?: (value: string) => string },
    atob: atobBinary,
    console,
    decodeURIComponent,
    String,
    Uint8Array,
    Array,
    Math,
    Function
  };

  vm.runInNewContext(atob2Block, context, { timeout: 1000 });

  if (typeof context.window.atob2 !== "function") {
    fail("window.atob2 decoder did not install");
  }

  return context.window.atob2;
}

function decodeCfPlaylist(js: string, atob2: (value: string) => string): string {
  const vm = require("node:vm") as typeof import("node:vm");
  const context: Record<string, unknown> = {
    window: {},
    atob: atobBinary,
    atob2,
    console
  };

  context.eval = (code: string) => vm.runInNewContext(code, context, { timeout: 1000 });
  vm.runInNewContext(js, context, { timeout: 1000 });

  const playbackFunctionName = Object.keys(context).find((key) => key.startsWith("plu"));
  if (!playbackFunctionName || typeof context[playbackFunctionName] !== "function") {
    fail("Cannot resolve plu playback function");
  }

  const hlsUrl = (context[playbackFunctionName] as () => string)();

  if (!hlsUrl.includes(".m3u8")) {
    fail("Resolved playback function did not return an HLS URL");
  }

  return hlsUrl;
}

async function main(): Promise<void> {
  const station = Bun.argv[2];
  assertStation(station);

  const pageUrl = `https://www.881903.com/live/${station}`;
  const pageHtml = await fetchText(pageUrl, { headers: browserHeaders });
  const [keyA, keyB] = extractRetrieveKeys(pageHtml);
  const vueAppScript = extractVueAppScript(pageHtml);

  let initData: Record<string, unknown>;
  try {
    initData = extractInitData(vueAppScript);
  } catch {
    initData = extractInitDataWithoutDom(vueAppScript);
  }

  const left = initData[keyA];
  const right = initData[keyB];

  if (typeof left !== "string" || typeof right !== "string") {
    fail("retrievePlaybackLink keys are absent from init data");
  }

  const bootstrapUrl = `${atobUtf8(left + right)}&z=${randomAlphaNum(16)}`;
  const bootstrapResponse = await fetch(bootstrapUrl, {
    headers: browserHeaders,
    redirect: "manual"
  });

  const cfplaylistUrl = bootstrapResponse.headers.get("location");
  if (!cfplaylistUrl) {
    fail("Missing cfplaylist Location header");
  }

  const cfplaylistResponse = await fetch(cfplaylistUrl, { headers: browserHeaders });
  if (!cfplaylistResponse.ok) {
    fail(`cfplaylist fetch failed ${cfplaylistResponse.status}`);
  }

  const cookies = parseCloudFrontCookies(getSetCookies(cfplaylistResponse.headers));
  const cfplaylistJs = await cfplaylistResponse.text();
  const atob2 = await installAtob2();
  const hlsUrl = decodeCfPlaylist(cfplaylistJs, atob2);

  const output: ResolveOutput = {
    station,
    stationKey: stationMap[station],
    channel: typeof initData.channel === "number" ? initData.channel : null,
    generatedAt: new Date().toISOString(),
    pageUrl,
    bootstrapUrl,
    cfplaylistUrl,
    hlsUrl,
    cookies
  };

  process.stdout.write(`${JSON.stringify(output, null, 2)}\n`);
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
