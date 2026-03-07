/**
 * Gemini Chat Export - Background Service Worker
 * Handles file downloads and message relay between popup and content scripts.
 */

// Relay progress messages from content script to popup
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.action === 'exportProgress') {
    // Forward to popup
    chrome.runtime.sendMessage(message).catch(() => {
      // Popup might be closed, ignore
    });
  }

  if (message.action === 'downloadFile') {
    const { content, filename, mimeType } = message;
    const blob = new Blob([content], { type: mimeType || 'application/json' });
    const url = URL.createObjectURL(blob);

    chrome.downloads.download({
      url: url,
      filename: filename,
      saveAs: true,
    }, (downloadId) => {
      // Revoke the URL after download starts
      setTimeout(() => URL.revokeObjectURL(url), 10000);
      sendResponse({ success: true, downloadId });
    });

    return true;
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

    return true;
  }
});
