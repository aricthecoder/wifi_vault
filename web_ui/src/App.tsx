import React, { useState, useEffect } from 'react';
import { Download, Upload, ShieldCheck, X, File as FileIcon, Image as ImageIcon, Film, Music, FileText, Archive, Folder, Home, ChevronRight } from 'lucide-react';
import { motion, AnimatePresence } from 'framer-motion';

type VaultFile = {
  name: string;
  ext: string;
  size: string;
  isDir?: boolean;
};

function App() {
  const [isAuthenticated, setIsAuthenticated] = useState(false);
  const [pin, setPin] = useState('');
  const [error, setError] = useState('');
  
  const [files, setFiles] = useState<VaultFile[]>([]);
  const [selectedFiles, setSelectedFiles] = useState<Set<string>>(new Set());
  const [previewFile, setPreviewFile] = useState<VaultFile | null>(null);
  const [isUploading, setIsUploading] = useState(false);
  const [currentPath, setCurrentPath] = useState('');

  useEffect(() => {
    if (isAuthenticated) {
      fetchFiles();
    }
  }, [isAuthenticated, currentPath]);

  const handleLogin = async (e: React.FormEvent) => {
    e.preventDefault();
    try {
      const res = await fetch(`/api/login?pin=${pin}`, { method: 'POST' });
      if (res.ok) {
        setIsAuthenticated(true);
        setError('');
      } else {
        setError('Incorrect PIN. Try again.');
      }
    } catch (err) {
      setError('Connection error.');
    }
  };

  const fetchFiles = async () => {
    try {
      const res = await fetch(`/api/files?path=${encodeURIComponent(currentPath)}`);
      if (res.status === 401) {
        setIsAuthenticated(false);
        return;
      }
      const data = await res.json();
      setFiles(data);
    } catch (err) {
      console.error(err);
    }
  };

  const handleUpload = async (e: React.ChangeEvent<HTMLInputElement>) => {
    if (!e.target.files || e.target.files.length === 0) return;
    setIsUploading(true);
    
    for (let i = 0; i < e.target.files.length; i++) {
      const formData = new FormData();
      formData.append('file', e.target.files[i]);
      // Currently the backend only supports uploading to root. For subfolders, backend needs ?path= update. 
      // We will upload to root for now as requested.
      await fetch('/api/upload', {
        method: 'POST',
        body: formData,
      });
    }
    
    setIsUploading(false);
    fetchFiles();
  };


  const downloadSelectedAsZip = () => {
    const form = document.createElement('form');
    form.method = 'POST';
    form.action = '/api/download_selected_zip';
    
    const input = document.createElement('input');
    input.type = 'hidden';
    input.name = 'files';
    input.value = Array.from(selectedFiles).join('|');
    
    form.appendChild(input);
    document.body.appendChild(form);
    form.submit();
    document.body.removeChild(form);
    setSelectedFiles(new Set());
  };

  const downloadAll = () => {
    window.location.href = '/api/download_all';
  };

  const getIcon = (file: VaultFile) => {
    if (file.isDir) return <Folder size={48} color="#fbbf24" fill="#fde68a" />;
    const ext = file.ext;
    if (['jpg','jpeg','png','gif','webp'].includes(ext)) return <ImageIcon size={48} color="#60a5fa" />;
    if (['mp4','mov','mkv','avi'].includes(ext)) return <Film size={48} color="#f87171" />;
    if (['mp3','wav','m4a'].includes(ext)) return <Music size={48} color="#a78bfa" />;
    if (['pdf'].includes(ext)) return <FileText size={48} color="#fb923c" />;
    if (['zip','rar','tar','gz'].includes(ext)) return <Archive size={48} color="#fbbf24" />;
    return <FileIcon size={48} color="#94a3b8" />;
  };

  const canPreview = (ext: string) => {
    return ['jpg','jpeg','png','gif','webp','mp4','mov','mkv','avi','mp3','wav','m4a','pdf'].includes(ext);
  };

  const getFullPath = (fileName: string) => {
    return currentPath ? `${currentPath}/${fileName}` : fileName;
  };

  const handleCardClick = (file: VaultFile) => {
    if (file.isDir) {
      setCurrentPath(getFullPath(file.name));
      return;
    }

    if (canPreview(file.ext)) {
      setPreviewFile({ ...file, name: getFullPath(file.name) });
    } else {
      window.location.href = `/api/download?path=${encodeURIComponent(getFullPath(file.name))}`;
    }
  };

  const navigateToBreadcrumb = (index: number) => {
    const parts = currentPath.split('/');
    const newPath = parts.slice(0, index + 1).join('/');
    setCurrentPath(newPath);
  };

  if (!isAuthenticated) {
    return (
      <div className="login-container">
        <motion.div 
          initial={{ scale: 0.9, opacity: 0 }}
          animate={{ scale: 1, opacity: 1 }}
          className="glass-panel login-card"
        >
          <ShieldCheck size={48} color="#3b82f6" style={{ margin: '0 auto' }} />
          <h1>WiFi Vault</h1>
          <p style={{ color: 'var(--text-muted)' }}>Enter the 4-digit PIN shown on your phone to unlock.</p>
          <form onSubmit={handleLogin} style={{ display: 'flex', flexDirection: 'column', gap: '16px' }}>
            <input 
              type="password" 
              maxLength={4} 
              className="pin-input" 
              value={pin}
              onChange={(e) => setPin(e.target.value.replace(/[^0-9]/g, ''))}
              placeholder="••••"
              autoFocus
            />
            {error && <div style={{ color: '#ef4444' }}>{error}</div>}
            <button type="submit" className="btn" style={{ justifyContent: 'center' }}>Unlock Vault</button>
          </form>
        </motion.div>
      </div>
    );
  }

  const pathParts = currentPath.split('/').filter(Boolean);

  return (
    <div className="container">
      <header>
        <h1>WiFi Vault</h1>
        <div style={{ display: 'flex', gap: '12px' }}>
          <label className="btn btn-secondary">
            <Upload size={18} />
            Upload to Vault
            <input type="file" multiple onChange={handleUpload} style={{ display: 'none' }} />
          </label>
          <button className="btn btn-secondary" onClick={downloadAll}>
            <Download size={18} />
            Download All (ZIP)
          </button>
        </div>
      </header>

      {/* Breadcrumbs Navigation */}
      <div style={{ display: 'flex', alignItems: 'center', gap: '8px', marginBottom: '24px', padding: '12px', background: 'var(--card-bg)', borderRadius: '12px', border: '1px solid var(--border)' }}>
        <button 
          onClick={() => setCurrentPath('')} 
          style={{ background: 'transparent', border: 'none', cursor: 'pointer', display: 'flex', alignItems: 'center', color: currentPath ? 'var(--text-color)' : 'var(--accent)' }}
        >
          <Home size={18} style={{ marginRight: '4px' }} />
          Root
        </button>
        {pathParts.map((part, index) => (
          <React.Fragment key={index}>
            <ChevronRight size={16} color="var(--text-muted)" />
            <button 
              onClick={() => navigateToBreadcrumb(index)}
              style={{ background: 'transparent', border: 'none', cursor: 'pointer', fontSize: '15px', color: index === pathParts.length - 1 ? 'var(--accent)' : 'var(--text-color)', fontWeight: index === pathParts.length - 1 ? 'bold' : 'normal' }}
            >
              {part}
            </button>
          </React.Fragment>
        ))}
      </div>

      <div className="file-grid">
        <AnimatePresence>
          {files.map((file) => {
            const fullPath = getFullPath(file.name);
            return (
              <motion.div
                layout
                initial={{ opacity: 0, y: 20 }}
                animate={{ opacity: 1, y: 0 }}
                exit={{ opacity: 0, scale: 0.9 }}
                key={fullPath}
                className={`glass-panel file-card ${selectedFiles.has(fullPath) ? 'selected' : ''}`}
                onClick={() => handleCardClick(file)}
              >
                {!file.isDir && (
                  <div className="checkbox-wrapper" onClick={(e) => e.stopPropagation()}>
                    <input 
                      type="checkbox" 
                      checked={selectedFiles.has(fullPath)}
                      onChange={(e) => {
                        const newSet = new Set(selectedFiles);
                        if (e.target.checked) newSet.add(fullPath);
                        else newSet.delete(fullPath);
                        setSelectedFiles(newSet);
                      }}
                    />
                  </div>
                )}
                
                <div className="file-icon-container">
                  {getIcon(file)}
                </div>
                
                <div className="file-name" title={file.name}>{file.name}</div>
                
                <div className="file-meta">
                  <span>{file.size}</span>
                  {!file.isDir && (
                    <a 
                      href={`/api/download?path=${encodeURIComponent(fullPath)}`} 
                      download={file.name}
                      onClick={(e) => e.stopPropagation()}
                      style={{ color: 'var(--accent)', textDecoration: 'none' }}
                    >
                      Download
                    </a>
                  )}
                </div>
              </motion.div>
            );
          })}
        </AnimatePresence>
        
        {files.length === 0 && (
          <div style={{ gridColumn: '1 / -1', textAlign: 'center', padding: '40px', color: 'var(--text-muted)' }}>
            This folder is empty.
          </div>
        )}
      </div>

      <AnimatePresence>
        {selectedFiles.size > 0 && (
          <motion.div 
            initial={{ y: 100, opacity: 0, x: '-50%' }}
            animate={{ y: 0, opacity: 1, x: '-50%' }}
            exit={{ y: 100, opacity: 0, x: '-50%' }}
            className="glass-panel fab-container"
          >
            <span style={{ alignSelf: 'center', fontWeight: 'bold' }}>{selectedFiles.size} files selected</span>
            <button className="btn" onClick={downloadSelectedAsZip}>
              <Download size={18} /> Zip & Download
            </button>
            <button className="btn btn-secondary" onClick={() => setSelectedFiles(new Set())}>
              Clear
            </button>
          </motion.div>
        )}
      </AnimatePresence>

      <AnimatePresence>
        {previewFile && (
          <motion.div 
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            className="lightbox"
            onClick={() => setPreviewFile(null)}
          >
            <button className="lightbox-close" onClick={() => setPreviewFile(null)}>
              <X size={32} />
            </button>
            
            <div onClick={(e) => e.stopPropagation()} style={{ position: 'relative' }}>
              {['mp4','mov','mkv','avi'].includes(previewFile.ext) && (
                <video controls autoPlay className="lightbox-content" src={`/api/view?path=${encodeURIComponent(previewFile.name)}`} />
              )}
              {['mp3','wav','m4a'].includes(previewFile.ext) && (
                <audio controls autoPlay src={`/api/view?path=${encodeURIComponent(previewFile.name)}`} />
              )}
              {['pdf'].includes(previewFile.ext) && (
                <iframe className="lightbox-content" src={`/api/view?path=${encodeURIComponent(previewFile.name)}`} style={{ width: '80vw', height: '80vh', background: 'white' }} />
              )}
              {['jpg','jpeg','png','gif','webp'].includes(previewFile.ext) && (
                <img className="lightbox-content" src={`/api/view?path=${encodeURIComponent(previewFile.name)}`} alt="Preview" />
              )}
              <div style={{ color: 'white', marginTop: '16px', textAlign: 'center', fontSize: '18px' }}>
                {previewFile.name.split('/').pop()}
              </div>
            </div>
          </motion.div>
        )}
      </AnimatePresence>

      {isUploading && (
        <div className="overlay-loader">
          <div className="loader"></div>
          <div>Uploading... Please wait</div>
        </div>
      )}
    </div>
  );
}

export default App;
