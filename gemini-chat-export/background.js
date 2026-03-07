/**
 * Gemini Chat Export - Background Service Worker
 * Handles file downloads.
 *
 * Note: URL.createObjectURL is NOT available in MV3 service workers,
 * so we convert content to a data: URI for downloads.
 */

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.action === 'exportProgress') {
    // Forward to popup (best-effort, popup may be closed)
    chrome.runtime.sendMessage(message).catch(() => {});
    return;
  }

  if (message.action === 'downloadFile') {
    const { content, filename, mimeType } = message;

    // Encode content as base64 data URI (service workers lack URL.createObjectURL)
    const base64 = btoa(unescape(encodeURIComponent(content)));
    const dataUrl = `data:${mimeType || 'application/octet-stream'};base64,${base64}`;

    chrome.downloads.download({
      url: dataUrl,
      filename: filename,
      saveAs: true,
    }, (downloadId) => {
      sendResponse({ success: true, downloadId });
    });

    return true; // async response needed for downloads.download callback
  }

  if (message.action === 'downloadBlob') {
    const { url, filename } = message;
    chrome.downloads.download({
      url: url,
      filename: filename,
      saveAs: false,
    }, (downloadId) => {
      sendResponse({ success: true, downloadId });
    });

    return true; // async response needed
  }
});
