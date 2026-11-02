// DuetPlus: YouTube audio over SABR (googlevideo) inside a hidden WebView.
// Runs on a https://www.youtube.com origin page (real browser engine), so
// BotGuard runs natively. Exposes window.duetFetchAudio(videoId, reqId).
// Bytes are handed to the host app through window.duetEmit(event, reqId, payload)
// which the app maps to its JS bridge (flutter_inappwebview callHandler).
import { Innertube, Platform, Constants, YTNodes } from 'youtubei.js/web';
import { buildSabrFormat, EnabledTrackTypes } from 'googlevideo/utils';
import { SabrStream } from 'googlevideo/sabr-stream';
import { BotGuardClient } from 'bgutils-js/botguard';
import { WebPoMinter } from 'bgutils-js/webpo';
import { buildURL, getHeaders, parseLooseJSON } from 'bgutils-js/utils';

declare global {
  interface Window {
    duetFetchAudio: (videoId: string, reqId: number) => Promise<void>;
    duetEmit: (event: string, reqId: number, payload: unknown) => void;
  }
}

Platform.shim.eval = async (data: any) => new Function(data.output)();

// Libraries store `fetch` and call it detached; browsers then throw
// "Illegal invocation". Bind it once.
window.fetch = window.fetch.bind(window);
const boundFetch = (input: any, init?: any) => window.fetch(input, init);
(Platform.shim as any).fetch = boundFetch;

// ------------------------------------------------------------ PO token minter
let minterPromise: Promise<WebPoMinter> | null = null;
let minterAt = 0;
let pageHtml: Promise<string> | null = null;
let visitorData: string | undefined;

// One youtube.com page load gives both the BotGuard challenge and the
// visitor id the browser (cookies) is known as. The InnerTube session must
// use the same visitor id, or the PO token is refused after ~1 MB.
function homePage(): Promise<string> {
  pageHtml ??= fetch('/', { credentials: 'include' }).then((r) => r.text());
  return pageHtml;
}

async function createMinter(): Promise<WebPoMinter> {
  const html = await homePage();
  const ytConfig = html.match(/ytcfg\.set\(({.+?})\);/s)?.[1];
  if (ytConfig) {
    const cfg = JSON.parse(ytConfig);
    (window as any).yt = { config_: cfg };
    visitorData = cfg.VISITOR_DATA ?? cfg.INNERTUBE_CONTEXT?.client?.visitorData;
  }
  window.duetEmit('log', 0, `page ${html.length} bytes, ytcfg=${!!ytConfig}, visitor=${visitorData ? visitorData.slice(0, 10) + '…' : 'none'}, ua=${navigator.userAgent.slice(0, 60)}`);
  const att = html.match(/window\.ytAtN\(\s*({[\s\S]*?})\s*\)/);
  if (!att) throw new Error('Could not find BotGuard challenge in page');
  const challenge = (parseLooseJSON(att[1]) as any).R;
  if (!challenge?.bgChallenge) throw new Error('No bgChallenge');
  const url = challenge.bgChallenge.interpreterUrl.privateDoNotAccessOrElseTrustedResourceUrlWrappedValue;
  // Load the interpreter like the web player does: a <script> tag (no CORS).
  await new Promise<void>((resolve, reject) => {
    const s = document.createElement('script');
    s.src = `https:${url}`;
    s.onload = () => resolve();
    s.onerror = () => reject(new Error('Could not load BotGuard interpreter'));
    document.head.appendChild(s);
  });
  const client = await BotGuardClient.create({
    program: challenge.bgChallenge.program,
    globalName: challenge.bgChallenge.globalName,
    globalObject: window,
  });
  const webPoSignalOutput: any[] = [];
  const bgResponse = await client.snapshot({ webPoSignalOutput });
  const r = await fetch(buildURL('GenerateIT', true), {
    method: 'POST',
    headers: getHeaders(),
    body: JSON.stringify(['O43z0dpjhgX20SCx4KAo', bgResponse]),
  });
  const [integrityToken, estimatedTtlSecs, mintRefreshThreshold, websafeFallbackToken] = await r.json();
  return WebPoMinter.create({ integrityToken, estimatedTtlSecs, mintRefreshThreshold, websafeFallbackToken }, webPoSignalOutput);
}

function minter(): Promise<WebPoMinter> {
  // Integrity tokens live ~12 h; refresh well before.
  if (!minterPromise || Date.now() - minterAt > 6 * 3600 * 1000) {
    minterAt = Date.now();
    minterPromise = createMinter().catch((e) => {
      minterPromise = null;
      throw e;
    });
  }
  return minterPromise;
}

// ------------------------------------------------------------ InnerTube
let ytPromise: Promise<Innertube> | null = null;
function innertube(): Promise<Innertube> {
  ytPromise ??= minter()
    .then(() => Innertube.create({ retrieve_player: true, fetch: boundFetch as any, visitor_data: visitorData }))
    .catch((e) => {
    ytPromise = null;
    throw e;
  });
  return ytPromise;
}

async function playerRequest(yt: Innertube, videoId: string, reloadPlaybackContext?: any) {
  const ep = new YTNodes.NavigationEndpoint({ watchEndpoint: { videoId } });
  const args: Record<string, any> = {
    playbackContext: {
      contentPlaybackContext: { vis: 0, splay: false, signatureTimestamp: yt.session.player?.signature_timestamp },
    },
    contentCheckOk: true,
    racyCheckOk: true,
    client: 'WEB',
  };
  if (reloadPlaybackContext) args.playbackContext.reloadPlaybackContext = reloadPlaybackContext;
  return (await ep.call(yt.actions, { ...args, parse: true })) as any;
}

function b64(u8: Uint8Array): string {
  let s = '';
  for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode(...u8.subarray(i, i + 0x8000));
  return btoa(s);
}

// ------------------------------------------------------------ audio fetch
window.duetFetchAudio = async (videoId: string, reqId: number) => {
  try {
    const mint = await minter();
    const yt = await innertube();
    const pr = await playerRequest(yt, videoId);
    if (pr.playability_status?.status !== 'OK') throw new Error(`Not playable: ${pr.playability_status?.reason ?? pr.playability_status?.status}`);
    const sabrUrl = await yt.session.player?.decipher(pr.streaming_data?.server_abr_streaming_url);
    const ustreamer = pr.player_config?.media_common_config.media_ustreamer_request_config?.video_playback_ustreamer_config;
    if (!sabrUrl || !ustreamer) throw new Error('Streaming info missing');
    const clientName = parseInt((Constants.CLIENT_NAME_IDS as any)[yt.session.context.client.clientName]);
    const stream = new SabrStream({
      videoId,
      formats: (pr.streaming_data?.adaptive_formats ?? []).map(buildSabrFormat),
      serverAbrStreamingUrl: sabrUrl,
      videoPlaybackUstreamerConfig: ustreamer,
      clientInfo: { clientName, clientVersion: yt.session.context.client.clientVersion },
      fetch: boundFetch,
      callbacks: {
        onMintPoToken: () => mint.mint(videoId),
        onReloadPlayerResponse: async (ctx: any) => {
          const p2 = await playerRequest(yt, videoId, ctx);
          return {
            serverAbrStreamingUrl: await yt.session.player?.decipher(p2.streaming_data?.server_abr_streaming_url),
            videoPlaybackUstreamerConfig:
              p2.player_config?.media_common_config.media_ustreamer_request_config?.video_playback_ustreamer_config,
          } as any;
        },
      },
    } as any);
    const { audioStream, selectedFormats } = stream.start({
      audioPreferences: { container: 'webm', dynamicRangeCompression: false, voiceBoost: false },
      enabledTrackTypes: EnabledTrackTypes.AUDIO_ONLY,
      isPostLiveDvr: false,
    } as any);
    const fmt = selectedFormats.audioFormat;
    window.duetEmit('begin', reqId, { mime: fmt.mimeType, size: Number(fmt.contentLength ?? 0), itag: fmt.itag });
    const reader = (audioStream as ReadableStream<Uint8Array>).getReader();
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      if (value?.length) window.duetEmit('chunk', reqId, b64(value));
    }
    window.duetEmit('end', reqId, null);
  } catch (e: any) {
    window.duetEmit('error', reqId, `${e?.message ?? e} @ ${String(e?.stack ?? '').split('\n').slice(1, 4).join(' | ')}`);
  }
};

window.duetEmit ??= () => {};
(window as any).duetReady = true;
