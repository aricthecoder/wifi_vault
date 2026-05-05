import React, { useState, useEffect, useRef } from 'react';

type Tab = 'files' | 'share' | 'clipboard' | 'chat' | 'speedtest' | 'tools';
type VaultFile = { name: string; ext: string; size: string; isDir?: boolean };
type ShareItem = { token: string; fileName: string; fileSizeFormatted: string; shareUrl: string; downloadCount: number; ttlSeconds: number; expiresAt: string };
type ChatMsg = { type: 'message' | 'system'; sender?: string; text: string; timestamp: string };
type Stats = { uptime: string; totalRequests: number; bytesInFormatted: string; bytesOutFormatted: string; uniqueClients: number; requestsPerMin: number; chatClients: number };

export default function App() {
  const [authed, setAuthed] = useState(false);
  const [pin, setPin] = useState('');
  const [pinError, setPinError] = useState('');
  const [tab, setTab] = useState<Tab>('files');

  // Files
  const [files, setFiles] = useState<VaultFile[]>([]);
  const [curPath, setCurPath] = useState('');
  const [uploading, setUploading] = useState(false);

  // Share
  const [shares, setShares] = useState<ShareItem[]>([]);
  const [shareUploading, setShareUploading] = useState(false);
  const [newShare, setNewShare] = useState<ShareItem | null>(null);
  const [copied, setCopied] = useState('');

  // Clipboard
  const [phoneClip, setPhoneClip] = useState('');
  const [sendClip, setSendClip] = useState('');

  // Chat
  const [msgs, setMsgs] = useState<ChatMsg[]>([]);
  const [chatInput, setChatInput] = useState('');
  const wsRef = useRef<WebSocket | null>(null);
  const chatBottomRef = useRef<HTMLDivElement>(null);

  // Speed Test
  const [testRunning, setTestRunning] = useState(false);
  const [testPhase, setTestPhase] = useState('');
  const [pingMs, setPingMs] = useState<number | null>(null);
  const [dlMbps, setDlMbps] = useState<number | null>(null);
  const [ulMbps, setUlMbps] = useState<number | null>(null);

  // Tools
  const [stats, setStats] = useState<Stats | null>(null);
  const [mac, setMac] = useState('');
  const [wolMsg, setWolMsg] = useState('');
  const [scanning, setScanning] = useState(false);
  const [scanResults, setScanResults] = useState<{ip:string;hostname:string;responseMs:number}[]>([]);

  const headers = { 'X-Vault-Pin': pin };

  useEffect(() => {
    if (!authed) return;
    if (tab === 'files') fetchFiles();
    if (tab === 'share') fetchShares();
    if (tab === 'clipboard') fetchClip();
    if (tab === 'chat') connectChat();
    if (tab === 'tools') { fetchStats(); const t = setInterval(fetchStats, 3000); return () => clearInterval(t); }
    return () => { if (tab !== 'chat' && wsRef.current) { wsRef.current.close(); wsRef.current = null; } };
  }, [authed, tab, curPath]);

  useEffect(() => { chatBottomRef.current?.scrollIntoView({ behavior: 'smooth' }); }, [msgs]);

  async function login(e: React.FormEvent) {
    e.preventDefault();
    const r = await fetch(`/api/login?pin=${pin}`, { method: 'POST' });
    if (r.ok) { setAuthed(true); setPinError(''); }
    else setPinError('Incorrect PIN');
  }

  async function fetchFiles() {
    const r = await fetch(`/api/files?path=${encodeURIComponent(curPath)}`, { headers });
    if (r.ok) setFiles(await r.json());
  }

  async function fetchShares() {
    const r = await fetch('/api/share/list', { headers });
    if (r.ok) setShares(await r.json());
  }

  async function fetchClip() {
    const r = await fetch('/api/clipboard', { headers });
    if (r.ok) { const d = await r.json(); setPhoneClip(d.text || ''); }
  }

  async function fetchStats() {
    const r = await fetch('/api/stats', { headers });
    if (r.ok) setStats(await r.json());
  }

  function connectChat() {
    if (wsRef.current) return;
    const ws = new WebSocket(`ws://${location.host}/ws/chat`);
    ws.onmessage = e => {
      const m = JSON.parse(e.data) as ChatMsg;
      setMsgs(prev => [...prev.slice(-99), m]);
    };
    ws.onclose = () => { wsRef.current = null; };
    wsRef.current = ws;
  }

  function sendChat(e: React.FormEvent) {
    e.preventDefault();
    if (!chatInput.trim() || !wsRef.current) return;
    wsRef.current.send(JSON.stringify({ text: chatInput }));
    setChatInput('');
  }

  async function handleShareUpload(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]; if (!file) return;
    setShareUploading(true); setNewShare(null);
    const fd = new FormData(); fd.append('file', file);
    const r = await fetch('/api/share/upload', { method: 'POST', headers, body: fd });
    if (r.ok) { const d = await r.json(); setNewShare(d); fetchShares(); }
    setShareUploading(false);
  }

  async function deleteShare(token: string) {
    await fetch(`/api/share/delete/${token}`, { method: 'POST', headers });
    fetchShares();
  }

  function copyLink(url: string, token: string) {
    navigator.clipboard.writeText(url);
    setCopied(token); setTimeout(() => setCopied(''), 2000);
  }

  async function runSpeedTest() {
    setTestRunning(true); setPingMs(null); setDlMbps(null); setUlMbps(null);
    // Ping (5 RTT samples)
    setTestPhase('Measuring latency...');
    let totalMs = 0;
    for (let i = 0; i < 5; i++) {
      const t0 = performance.now();
      await fetch('/api/speedtest/ping', { headers });
      totalMs += performance.now() - t0;
    }
    setPingMs(Math.round(totalMs / 5));
    // Download
    setTestPhase('Testing download speed...');
    const t1 = performance.now();
    const dlRes = await fetch('/api/speedtest/download?size=10', { headers });
    const buf = await dlRes.arrayBuffer();
    const dlTime = (performance.now() - t1) / 1000;
    setDlMbps(parseFloat(((buf.byteLength * 8) / dlTime / 1e6).toFixed(2)));
    // Upload
    setTestPhase('Testing upload speed...');
    const chunk = new Uint8Array(5 * 1024 * 1024);
    const ulRes = await fetch('/api/speedtest/upload', { method: 'POST', headers, body: chunk });
    const ulData = await ulRes.json();
    setUlMbps(parseFloat(ulData.mbps));
    setTestPhase('Done!'); setTestRunning(false);
  }

  async function sendWol(e: React.FormEvent) {
    e.preventDefault();
    const r = await fetch('/api/wol', { method: 'POST', headers: { ...headers, 'Content-Type': 'application/json' }, body: JSON.stringify({ mac }) });
    const d = await r.json();
    setWolMsg(d.success ? `✅ Magic packet sent to ${mac}` : `❌ ${d.error}`);
    setTimeout(() => setWolMsg(''), 4000);
  }

  async function runScan() {
    setScanning(true); setScanResults([]);
    const r = await fetch('/api/scan', { headers });
    if (r.ok) setScanResults(await r.json());
    setScanning(false);
  }

  async function handleFileUpload(e: React.ChangeEvent<HTMLInputElement>) {
    if (!e.target.files?.length) return;
    setUploading(true);
    for (const f of Array.from(e.target.files)) {
      const fd = new FormData(); fd.append('file', f);
      await fetch('/api/upload', { method: 'POST', headers, body: fd });
    }
    setUploading(false); fetchFiles();
  }

  const fmtTtl = (secs: number) => {
    const h = Math.floor(secs / 3600); const m = Math.floor((secs % 3600) / 60);
    return h > 0 ? `${h}h ${m}m` : `${m}m`;
  };

  if (!authed) return (
    <div className="login-wrap">
      <div className="login-card glass">
        <div className="lock-icon">🔒</div>
        <h1>WiFi Vault</h1>
        <p className="muted">Enter the 4-digit PIN from your phone</p>
        <form onSubmit={login}>
          <input className="pin-inp" type="password" maxLength={4} placeholder="••••" value={pin}
            onChange={e => setPin(e.target.value.replace(/\D/g, ''))} autoFocus />
          {pinError && <p className="err">{pinError}</p>}
          <button className="btn" type="submit">Unlock Vault</button>
        </form>
      </div>
    </div>
  );

  const TABS: { id: Tab; label: string; icon: string }[] = [
    { id: 'files', label: 'Files', icon: '📁' },
    { id: 'share', label: 'Share', icon: '🔗' },
    { id: 'clipboard', label: 'Clipboard', icon: '📋' },
    { id: 'chat', label: 'Chat', icon: '💬' },
    { id: 'speedtest', label: 'Speed', icon: '📶' },
    { id: 'tools', label: 'Tools', icon: '🛠️' },
  ];

  return (
    <div className="app">
      <header className="header">
        <h1 className="brand">WiFi Vault</h1>
        <nav className="tabs">
          {TABS.map(t => (
            <button key={t.id} className={`tab-btn ${tab === t.id ? 'active' : ''}`} onClick={() => setTab(t.id)}>
              <span>{t.icon}</span> <span className="tab-label">{t.label}</span>
            </button>
          ))}
        </nav>
      </header>

      <main className="main">

        {/* ── FILES TAB ── */}
        {tab === 'files' && (
          <div>
            <div className="toolbar">
              <label className="btn btn-sm">⬆️ Upload <input type="file" multiple style={{ display: 'none' }} onChange={handleFileUpload} /></label>
              <button className="btn btn-sm btn-ghost" onClick={() => { window.location.href = '/api/download_all'; }}>⬇️ Download All</button>
            </div>
            {uploading && <div className="notice">Uploading...</div>}
            <div className="breadcrumb">
              <button onClick={() => setCurPath('')}>🏠 Root</button>
              {curPath.split('/').filter(Boolean).map((p, i, arr) => (
                <span key={i}> / <button onClick={() => setCurPath(arr.slice(0, i + 1).join('/'))}>{p}</button></span>
              ))}
            </div>
            <div className="file-grid">
              {files.map(f => {
                const full = curPath ? `${curPath}/${f.name}` : f.name;
                return (
                  <div key={full} className="file-card glass" onClick={() => f.isDir ? setCurPath(full) : window.open(`/api/view?path=${encodeURIComponent(full)}`)}>
                    <div className="file-icon">{f.isDir ? '📁' : '📄'}</div>
                    <div className="file-name" title={f.name}>{f.name}</div>
                    <div className="file-meta">
                      <span>{f.size}</span>
                      {!f.isDir && <a href={`/api/download?path=${encodeURIComponent(full)}`} onClick={e => e.stopPropagation()} download>↓</a>}
                    </div>
                  </div>
                );
              })}
              {!files.length && <div className="empty">This folder is empty.</div>}
            </div>
          </div>
        )}

        {/* ── SHARE TAB ── */}
        {tab === 'share' && (
          <div className="share-page">
            <div className="section-header">
              <h2>📤 Shareable Links</h2>
              <p className="muted">Upload a file to get a public link — valid for 24 hours, downloadable by anyone.</p>
            </div>

            {/* CN Concepts Banner */}
            <div className="cn-banner glass">
              <span className="cn-tag">🔑 Capability URLs</span>
              <span className="cn-tag">⏱ TTL 24h</span>
              <span className="cn-tag">🌐 HTTP Content-Disposition</span>
              <span className="cn-tag">🔄 Concurrent TCP Streams</span>
            </div>

            {/* Upload Zone */}
            <label className="upload-zone glass">
              <input type="file" style={{ display: 'none' }} onChange={handleShareUpload} disabled={shareUploading} />
              {shareUploading ? (
                <div className="uploading-state">
                  <div className="spinner"></div>
                  <p>Uploading & generating link...</p>
                </div>
              ) : (
                <div className="upload-prompt">
                  <div style={{ fontSize: 48 }}>📦</div>
                  <p style={{ fontWeight: 700, fontSize: 18, marginTop: 8 }}>Click to Upload File</p>
                  <p className="muted">Any file type · Max size limited by device RAM</p>
                </div>
              )}
            </label>

            {/* New Share Result */}
            {newShare && (
              <div className="share-result glass">
                <div className="share-result-icon">✅</div>
                <div className="share-result-info">
                  <strong>{newShare.fileName}</strong>
                  <span className="muted"> · {newShare.fileSizeFormatted}</span>
                </div>
                <div className="share-url-row">
                  <input className="share-url-input" readOnly value={newShare.shareUrl} />
                  <button className="btn btn-sm" onClick={() => copyLink(newShare.shareUrl, 'new')}>
                    {copied === 'new' ? '✅ Copied!' : '📋 Copy'}
                  </button>
                </div>
                <p className="muted" style={{ fontSize: 12, marginTop: 8 }}>
                  Expires in {fmtTtl(newShare.ttlSeconds)} · Anyone with this link can download
                </p>
              </div>
            )}

            {/* Active Shares List */}
            <h3 style={{ marginTop: 32, marginBottom: 16 }}>Active Shares ({shares.length})</h3>
            {shares.length === 0 && <div className="empty">No active shares. Upload a file above.</div>}
            <div className="share-list">
              {shares.map(s => (
                <div key={s.token} className="share-item glass">
                  <div className="share-item-top">
                    <div>
                      <div className="share-file-name">{s.fileName}</div>
                      <div className="muted" style={{ fontSize: 12 }}>
                        {s.fileSizeFormatted} · ⬇️ {s.downloadCount} downloads · ⏱ {fmtTtl(s.ttlSeconds)} left
                      </div>
                    </div>
                    <button className="btn-icon danger" onClick={() => deleteShare(s.token)} title="Revoke link">🗑</button>
                  </div>
                  <div className="share-url-row">
                    <code className="share-token">{s.shareUrl}</code>
                    <button className="btn btn-sm" onClick={() => copyLink(s.shareUrl, s.token)}>
                      {copied === s.token ? '✅' : '📋'}
                    </button>
                  </div>
                  <div style={{ marginTop: 8 }}>
                    <a className="btn btn-sm btn-ghost" href={`${s.shareUrl}/download`} target="_blank" rel="noreferrer">⬇️ Download</a>
                  </div>
                  {/* TTL progress bar */}
                  <div className="ttl-bar-wrap">
                    <div className="ttl-bar" style={{ width: `${Math.max(0, (s.ttlSeconds / 86400) * 100).toFixed(1)}%` }}></div>
                  </div>
                </div>
              ))}
            </div>
          </div>
        )}

        {/* ── CLIPBOARD TAB ── */}
        {tab === 'clipboard' && (
          <div className="panel-2col">
            <div className="glass card-pad">
              <h3>📱 Phone's Clipboard</h3>
              <p className="muted">Currently copied on your phone:</p>
              <div className="clip-area">{phoneClip || <em className="muted">Empty</em>}</div>
              <button className="btn" onClick={() => navigator.clipboard.writeText(phoneClip)} disabled={!phoneClip} style={{ marginTop: 12 }}>📋 Copy to PC</button>
            </div>
            <div className="glass card-pad">
              <h3>💻 Send to Phone</h3>
              <p className="muted">Type or paste text to copy it to your phone:</p>
              <textarea className="clip-write" rows={5} value={sendClip} onChange={e => setSendClip(e.target.value)} placeholder="Enter text..." />
              <button className="btn" style={{ marginTop: 12 }} disabled={!sendClip}
                onClick={async () => { await fetch('/api/clipboard', { method: 'POST', headers: { ...headers, 'Content-Type': 'application/json' }, body: JSON.stringify({ text: sendClip }) }); setSendClip(''); }}>
                📤 Send to Phone
              </button>
            </div>
          </div>
        )}

        {/* ── CHAT TAB ── */}
        {tab === 'chat' && (
          <div className="chat-container">
            <div className="cn-banner glass">
              <span className="cn-tag">🔌 WebSocket (RFC 6455)</span>
              <span className="cn-tag">⚡ Full-Duplex TCP</span>
              <span className="cn-tag">📡 HTTP Upgrade Handshake</span>
            </div>
            <div className="chat-messages glass">
              {msgs.map((m, i) => (
                <div key={i} className={`chat-msg ${m.type}`}>
                  {m.type === 'message' && <span className="chat-sender">{m.sender}: </span>}
                  <span>{m.text}</span>
                  <span className="chat-time">{new Date(m.timestamp).toLocaleTimeString()}</span>
                </div>
              ))}
              {!msgs.length && <div className="empty">No messages yet. Say hello!</div>}
              <div ref={chatBottomRef} />
            </div>
            <form className="chat-input-row" onSubmit={sendChat}>
              <input className="chat-inp" value={chatInput} onChange={e => setChatInput(e.target.value)} placeholder="Type a message..." />
              <button className="btn" type="submit">Send</button>
            </form>
          </div>
        )}

        {/* ── SPEED TEST TAB ── */}
        {tab === 'speedtest' && (
          <div className="speed-page">
            <div className="cn-banner glass">
              <span className="cn-tag">📶 Throughput Measurement</span>
              <span className="cn-tag">⏱ RTT / Latency</span>
              <span className="cn-tag">🌐 Bandwidth Estimation</span>
            </div>
            <div className="speed-results glass">
              <div className="speed-metric">
                <div className="speed-val">{pingMs !== null ? `${pingMs}ms` : '--'}</div>
                <div className="speed-label">Ping (RTT)</div>
              </div>
              <div className="speed-metric">
                <div className="speed-val" style={{ color: '#34d399' }}>{dlMbps !== null ? `${dlMbps}` : '--'}</div>
                <div className="speed-label">Download (Mbps)</div>
              </div>
              <div className="speed-metric">
                <div className="speed-val" style={{ color: '#fb923c' }}>{ulMbps !== null ? `${ulMbps}` : '--'}</div>
                <div className="speed-label">Upload (Mbps)</div>
              </div>
            </div>
            {testPhase && <div className="notice">{testPhase}</div>}
            <button className="btn btn-lg" onClick={runSpeedTest} disabled={testRunning} style={{ marginTop: 24 }}>
              {testRunning ? '⏳ Testing...' : '▶ Run Speed Test'}
            </button>
          </div>
        )}

        {/* ── TOOLS TAB ── */}
        {tab === 'tools' && (
          <div>
            {/* Network Stats */}
            <h3 style={{ marginBottom: 16 }}>📊 Network Stats</h3>
            <div className="cn-banner glass">
              <span className="cn-tag">📈 Live Telemetry</span>
              <span className="cn-tag">🔢 Protocol Counters</span>
            </div>
            {stats && (
              <div className="stats-grid">
                {[
                  { label: 'Uptime', val: stats.uptime, icon: '⏱' },
                  { label: 'Total Requests', val: stats.totalRequests, icon: '📨' },
                  { label: 'Data Downloaded', val: stats.bytesOutFormatted, icon: '⬇️' },
                  { label: 'Data Uploaded', val: stats.bytesInFormatted, icon: '⬆️' },
                  { label: 'Unique Clients', val: stats.uniqueClients, icon: '👤' },
                  { label: 'Req / Min', val: stats.requestsPerMin, icon: '⚡' },
                  { label: 'Chat Clients', val: stats.chatClients, icon: '💬' },
                ].map(s => (
                  <div key={s.label} className="stat-tile glass">
                    <div className="stat-icon">{s.icon}</div>
                    <div className="stat-val">{s.val}</div>
                    <div className="stat-label">{s.label}</div>
                  </div>
                ))}
              </div>
            )}

            {/* LAN Scanner */}
            <h3 style={{ margin: '32px 0 16px' }}>🔍 LAN Scanner</h3>
            <div className="cn-banner glass">
              <span className="cn-tag">🌐 Subnet /24 Sweep</span>
              <span className="cn-tag">🔌 TCP Reachability</span>
              <span className="cn-tag">🔎 DNS Reverse Lookup</span>
            </div>
            <button className="btn" onClick={runScan} disabled={scanning} style={{ marginBottom: 16 }}>
              {scanning ? '⏳ Scanning subnet...' : '🔍 Scan Network'}
            </button>
            {scanResults.length > 0 && (
              <div className="scan-list glass">
                <div className="scan-header"><span>IP Address</span><span>Hostname</span><span>Response</span></div>
                {scanResults.map(r => (
                  <div key={r.ip} className="scan-row">
                    <span className="scan-ip">{r.ip}</span>
                    <span className="muted">{r.hostname || '—'}</span>
                    <span className="scan-ms">{r.responseMs}ms</span>
                  </div>
                ))}
              </div>
            )}

            {/* Wake-on-LAN */}
            <h3 style={{ margin: '32px 0 16px' }}>💡 Wake-on-LAN</h3>
            <div className="cn-banner glass">
              <span className="cn-tag">🔮 UDP Magic Packet</span>
              <span className="cn-tag">📡 Layer 2 Broadcast</span>
              <span className="cn-tag">🖥 Remote Power On</span>
            </div>
            <div className="glass card-pad">
              <form onSubmit={sendWol} style={{ display: 'flex', gap: 12, flexWrap: 'wrap' }}>
                <input className="text-inp" placeholder="AA:BB:CC:DD:EE:FF" value={mac}
                  onChange={e => setMac(e.target.value)} style={{ flex: 1, minWidth: 200 }} />
                <button className="btn" type="submit">⚡ Wake Device</button>
              </form>
              {wolMsg && <div className="notice" style={{ marginTop: 12 }}>{wolMsg}</div>}
              <p className="muted" style={{ fontSize: 12, marginTop: 12 }}>
                Sends a 102-byte magic packet (6×0xFF + 16×MAC) via UDP broadcast on port 9.
              </p>
            </div>
          </div>
        )}

      </main>
    </div>
  );
}
