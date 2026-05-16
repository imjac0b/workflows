type ResolveOutput = {
  station: string;
  stationKey: string;
  hlsUrl: string;
  cookies: Record<string, string>;
};

const baseHeaders = {
  "User-Agent":
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome Safari/537.36",
  "Referer": "https://www.881903.com/",
  "Origin": "https://www.881903.com",
  "Accept": "*/*"
};

function fail(message: string): never {
  throw new Error(message);
}

function cookieHeader(cookies: Record<string, string>): string {
  return Object.entries(cookies)
    .map(([name, value]) => `${name}=${value}`)
    .join("; ");
}

function playlistItems(playlist: string): string[] {
  return playlist
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith("#"));
}

async function fetchRequired(url: string, headers: HeadersInit): Promise<Response> {
  const response = await fetch(url, { headers });

  if (!response.ok) {
    const text = await response.text();
    fail(`Fetch failed ${response.status} ${response.statusText}: ${url}\n${text.slice(0, 300)}`);
  }

  return response;
}

async function main(): Promise<void> {
  const file = Bun.argv[2];
  if (!file) {
    fail("Usage: bun run validate <resolver-json>");
  }

  const resolved = (await Bun.file(file).json()) as ResolveOutput;
  const headers = {
    ...baseHeaders,
    "Cookie": cookieHeader(resolved.cookies)
  };

  const masterResponse = await fetchRequired(resolved.hlsUrl, headers);
  const master = await masterResponse.text();

  if (!master.includes("#EXTM3U")) {
    fail("Master playlist does not contain #EXTM3U");
  }

  const masterItems = playlistItems(master);
  const chunksPath = masterItems.find((item) => item.includes(".m3u8"));

  if (!chunksPath) {
    fail("Master playlist does not contain chunks.m3u8");
  }

  const chunksUrl = new URL(chunksPath, resolved.hlsUrl).toString();
  const chunksResponse = await fetchRequired(chunksUrl, headers);
  const chunks = await chunksResponse.text();
  const segmentPath = playlistItems(chunks)
    .filter((item) => item.includes(".aac"))
    .at(-1);

  if (!segmentPath) {
    fail("Chunks playlist does not contain an AAC segment");
  }

  const segmentUrl = new URL(segmentPath, chunksUrl).toString();
  const segmentResponse = await fetchRequired(segmentUrl, headers);
  const segmentBytes = await segmentResponse.arrayBuffer();
  const contentType = segmentResponse.headers.get("content-type") || "";

  if (!contentType.includes("audio/aac")) {
    fail(`Unexpected segment content-type: ${contentType}`);
  }

  if (segmentBytes.byteLength < 10_000) {
    fail(`AAC segment is too small: ${segmentBytes.byteLength} bytes`);
  }

  console.log(
    JSON.stringify(
      {
        ok: true,
        station: resolved.station,
        stationKey: resolved.stationKey,
        masterStatus: masterResponse.status,
        chunksStatus: chunksResponse.status,
        segmentStatus: segmentResponse.status,
        segmentContentType: contentType,
        segmentBytes: segmentBytes.byteLength
      },
      null,
      2
    )
  );
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
