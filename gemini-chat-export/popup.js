/**
 * Gemini Chat Export - Popup Script
 * Handles UI interactions and coordinates export operations.
 */

(function () {
  'use strict';

  // DOM elements
  const mainPanel = document.getElementById('main-panel');
  const resultPanel = document.getElementById('result-panel');
  const notGemini = document.getElementById('not-gemini');
  const statusBar = document.getElementById('status-bar');
  const progressBar = document.getElementById('progress-bar');
  const statusText = document.getElementById('status-text');
  const resultSummary = document.getElementById('result-summary');

  const btnExport = document.getElementById('btn-export');
  const btnCancel = document.getElementById('btn-cancel');
  const btnDownload = document.getElementById('btn-download');
  const btnBack = document.getElementById('btn-back');

  const optConversations = document.getElementById('opt-conversations');
  const optAttachments = document.getElementById('opt-attachments');
  const optCodeBlocks = document.getElementById('opt-code-blocks');

  let exportedData = null;
  let exportCancelled = false;

  /**
   * Ensure the content script is injected into the active tab.
   * This handles the case where the extension was installed/reloaded
   * after the Gemini page was already open.
   */
  async function ensureContentScript(tabId) {
    try {
      // Try a ping first to see if content script is already loaded
      await chrome.tabs.sendMessage(tabId, { action: 'checkPage' });
    } catch (e) {
      // Content script not loaded — inject it programmatically
      await chrome.scripting.executeScript({
        target: { tabId: tabId },
        files: ['content.js'],
      });
      // Wait a moment for the script to initialize
      await new Promise(r => setTimeout(r, 300));
    }
  }

  /**
   * Send a message to the content script in the active tab.
   * Automatically injects the content script if not already present.
   */
  async function sendToContent(message) {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    await ensureContentScript(tab.id);
    return chrome.tabs.sendMessage(tab.id, message);
  }

  /**
   * Check if the current page is Gemini.
   */
  async function checkPage() {
    try {
      const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
      if (tab?.url?.includes('gemini.google.com')) {
        mainPanel.classList.remove('hidden');
        notGemini.classList.add('hidden');
        return true;
      }
    } catch (e) {
      // ignore
    }
    mainPanel.classList.add('hidden');
    notGemini.classList.remove('hidden');
    return false;
  }

  /**
   * Update progress UI.
   */
  function updateProgress(current, total, title) {
    const pct = Math.round((current / total) * 100);
    progressBar.style.width = pct + '%';
    statusText.textContent = `正在导出 (${current}/${total}): ${title || ''}`;
  }

  /**
   * Convert conversations to JSON string.
   */
  function toJSON(conversations, options) {
    const filtered = filterData(conversations, options);
    return JSON.stringify(filtered, null, 2);
  }

  /**
   * Convert conversations to Markdown string.
   */
  function toMarkdown(conversations, options) {
    const filtered = filterData(conversations, options);
    let md = '';

    for (const conv of filtered) {
      md += `# ${conv.title || 'Untitled Conversation'}\n\n`;
      md += `> Exported: ${conv.timestamp}\n`;
      md += `> URL: ${conv.url}\n\n`;
      md += '---\n\n';

      for (const msg of conv.messages) {
        const roleLabel = msg.role === 'user' ? '**You**' : '**Gemini**';
        md += `### ${roleLabel}\n\n`;
        if (msg.text) {
          md += msg.text + '\n\n';
        }
        if (options.codeBlocks && msg.codeBlocks?.length > 0) {
          for (const block of msg.codeBlocks) {
            md += '```' + (block.language || '') + '\n';
            md += block.code + '\n';
            md += '```\n\n';
          }
        }
        if (options.attachments && msg.images?.length > 0) {
          for (const img of msg.images) {
            md += `![${img.alt || 'image'}](${img.src})\n\n`;
          }
        }
        if (options.attachments && msg.attachments?.length > 0) {
          md += '**Attachments:**\n';
          for (const att of msg.attachments) {
            if (att.url) {
              md += `- [${att.name}](${att.url})\n`;
            } else {
              md += `- ${att.name}\n`;
            }
          }
          md += '\n';
        }
        md += '---\n\n';
      }
      md += '\n\n';
    }

    return md;
  }

  /**
   * Convert conversations to HTML string.
   */
  function toHTML(conversations, options) {
    const filtered = filterData(conversations, options);
    let html = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<title>Gemini Chat Export</title>
<style>
  body { font-family: 'Segoe UI', 'PingFang SC', sans-serif; max-width: 800px; margin: 0 auto; padding: 20px; background: #f8f9fa; }
  .conversation { background: #fff; border-radius: 12px; padding: 24px; margin-bottom: 24px; box-shadow: 0 2px 8px rgba(0,0,0,0.1); }
  .conv-title { font-size: 20px; color: #4285f4; margin-bottom: 8px; }
  .conv-meta { font-size: 12px; color: #888; margin-bottom: 16px; }
  .message { padding: 12px 16px; margin-bottom: 12px; border-radius: 8px; }
  .message.user { background: #e8f0fe; border-left: 4px solid #4285f4; }
  .message.model { background: #f0f0f0; border-left: 4px solid #34a853; }
  .role { font-weight: bold; font-size: 13px; color: #555; margin-bottom: 6px; }
  pre { background: #263238; color: #eeffff; padding: 12px; border-radius: 6px; overflow-x: auto; font-size: 13px; }
  code { font-family: 'Fira Code', monospace; }
  img { max-width: 100%; border-radius: 8px; margin: 8px 0; }
  .attachment { background: #fef7e0; padding: 8px 12px; border-radius: 6px; margin: 4px 0; font-size: 13px; }
  hr { border: none; border-top: 1px solid #e0e0e0; margin: 16px 0; }
</style>
</head>
<body>
<h1>Gemini Chat Export</h1>
<p style="color:#888;">Exported on ${new Date().toLocaleString('zh-CN')}</p>
<hr>\n`;

    for (const conv of filtered) {
      html += `<div class="conversation">\n`;
      html += `  <div class="conv-title">${escapeHtml(conv.title || 'Untitled')}</div>\n`;
      html += `  <div class="conv-meta">URL: ${escapeHtml(conv.url)} | ${conv.timestamp}</div>\n`;

      for (const msg of conv.messages) {
        const roleClass = msg.role === 'user' ? 'user' : 'model';
        const roleLabel = msg.role === 'user' ? 'You' : 'Gemini';
        html += `  <div class="message ${roleClass}">\n`;
        html += `    <div class="role">${roleLabel}</div>\n`;
        if (msg.text) {
          html += `    <p>${escapeHtml(msg.text)}</p>\n`;
        }
        if (options.codeBlocks && msg.codeBlocks?.length > 0) {
          for (const block of msg.codeBlocks) {
            html += `    <pre><code class="language-${escapeHtml(block.language)}">${escapeHtml(block.code)}</code></pre>\n`;
          }
        }
        if (options.attachments && msg.images?.length > 0) {
          for (const img of msg.images) {
            html += `    <img src="${escapeHtml(img.src)}" alt="${escapeHtml(img.alt)}">\n`;
          }
        }
        if (options.attachments && msg.attachments?.length > 0) {
          for (const att of msg.attachments) {
            html += `    <div class="attachment">📎 ${escapeHtml(att.name)}</div>\n`;
          }
        }
        html += `  </div>\n`;
      }
      html += `</div>\n`;
    }

    html += `</body>\n</html>`;
    return html;
  }

  function escapeHtml(str) {
    const div = document.createElement('div');
    div.textContent = str || '';
    return div.innerHTML;
  }

  /**
   * Filter exported data based on user options.
   */
  function filterData(conversations, options) {
    return conversations.map(conv => ({
      ...conv,
      messages: conv.messages.map(msg => {
        const filtered = { role: msg.role };
        if (options.conversations) {
          filtered.text = msg.text;
        }
        if (options.codeBlocks) {
          filtered.codeBlocks = msg.codeBlocks;
        }
        if (options.attachments) {
          filtered.images = msg.images;
          filtered.attachments = msg.attachments;
        }
        return filtered;
      }),
    }));
  }

  /**
   * Get the selected export format.
   */
  function getFormat() {
    return document.querySelector('input[name="format"]:checked')?.value || 'json';
  }

  /**
   * Get the selected export scope.
   */
  function getScope() {
    return document.querySelector('input[name="scope"]:checked')?.value || 'current';
  }

  /**
   * Get export options from checkboxes.
   */
  function getOptions() {
    return {
      conversations: optConversations.checked,
      attachments: optAttachments.checked,
      codeBlocks: optCodeBlocks.checked,
    };
  }

  /**
   * Count statistics from exported data.
   */
  function getStats(conversations) {
    let totalMessages = 0;
    let totalCodeBlocks = 0;
    let totalImages = 0;
    let totalAttachments = 0;

    for (const conv of conversations) {
      totalMessages += conv.messages?.length || 0;
      for (const msg of conv.messages || []) {
        totalCodeBlocks += msg.codeBlocks?.length || 0;
        totalImages += msg.images?.length || 0;
        totalAttachments += msg.attachments?.length || 0;
      }
    }

    return {
      conversations: conversations.length,
      messages: totalMessages,
      codeBlocks: totalCodeBlocks,
      images: totalImages,
      attachments: totalAttachments,
    };
  }

  /**
   * Main export handler.
   */
  async function startExport() {
    const scope = getScope();
    const options = getOptions();
    exportCancelled = false;

    // Show progress
    statusBar.classList.remove('hidden');
    btnExport.disabled = true;
    btnCancel.classList.remove('hidden');
    updateProgress(0, 1, '准备中...');

    try {
      let result;
      if (scope === 'current') {
        updateProgress(1, 1, '正在导出当前会话...');
        result = await sendToContent({ action: 'exportCurrent', options });
      } else {
        // Get list first
        updateProgress(0, 1, '获取会话列表...');
        const listResult = await sendToContent({ action: 'getConversationList' });

        if (!listResult.success || listResult.data.length === 0) {
          // Fall back to current conversation
          updateProgress(1, 1, '未找到会话列表，导出当前会话...');
          result = await sendToContent({ action: 'exportCurrent', options });
        } else {
          // Export each conversation by navigating the tab from the popup side.
          // We cannot navigate from content script as it destroys itself.
          const allData = [];
          const list = listResult.data;
          const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });

          for (let i = 0; i < list.length; i++) {
            if (exportCancelled) break;

            updateProgress(i + 1, list.length, list[i].title);

            // Navigate the tab to the conversation URL
            await chrome.tabs.update(tab.id, { url: list[i].url });

            // Wait for the page to finish loading
            await new Promise((resolve) => {
              function onUpdated(tabId, changeInfo) {
                if (tabId === tab.id && changeInfo.status === 'complete') {
                  chrome.tabs.onUpdated.removeListener(onUpdated);
                  // Extra delay for dynamic content rendering
                  setTimeout(resolve, 2000);
                }
              }
              chrome.tabs.onUpdated.addListener(onUpdated);
              // Timeout safety
              setTimeout(() => {
                chrome.tabs.onUpdated.removeListener(onUpdated);
                resolve();
              }, 15000);
            });

            // Inject content script into the newly loaded page and extract
            try {
              await chrome.scripting.executeScript({
                target: { tabId: tab.id },
                files: ['content.js'],
              });
              await new Promise(r => setTimeout(r, 300));
              const convResult = await chrome.tabs.sendMessage(tab.id, { action: 'exportCurrent' });
              if (convResult?.success && convResult.data) {
                const convData = convResult.data[0];
                convData.title = list[i].title || convData.title;
                allData.push(convData);
              }
            } catch (e) {
              // Skip this conversation on error
            }
          }

          result = { success: true, data: allData };
        }
      }

      if (exportCancelled) {
        statusText.textContent = '导出已取消';
        setTimeout(() => resetUI(), 1500);
        return;
      }

      if (!result?.success) {
        statusText.textContent = '导出失败: ' + (result?.error || '未知错误');
        setTimeout(() => resetUI(), 3000);
        return;
      }

      exportedData = result.data;
      showResults(result.data);
    } catch (err) {
      statusText.textContent = '导出出错: ' + err.message;
      setTimeout(() => resetUI(), 3000);
    }
  }

  /**
   * Show export results.
   */
  function showResults(data) {
    const stats = getStats(data);
    mainPanel.classList.add('hidden');
    statusBar.classList.add('hidden');
    resultPanel.classList.remove('hidden');

    resultSummary.innerHTML = `
      <p><strong>导出统计：</strong></p>
      <p>会话数量：${stats.conversations}</p>
      <p>消息数量：${stats.messages}</p>
      <p>代码块：${stats.codeBlocks}</p>
      <p>图片：${stats.images}</p>
      <p>附件：${stats.attachments}</p>
    `;
  }

  /**
   * Download the exported data.
   */
  function downloadExport() {
    if (!exportedData) return;

    const format = getFormat();
    const options = getOptions();
    const timestamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
    let content, filename, mimeType;

    switch (format) {
      case 'markdown':
        content = toMarkdown(exportedData, options);
        filename = `gemini-export-${timestamp}.md`;
        mimeType = 'text/markdown';
        break;
      case 'html':
        content = toHTML(exportedData, options);
        filename = `gemini-export-${timestamp}.html`;
        mimeType = 'text/html';
        break;
      case 'json':
      default:
        content = toJSON(exportedData, options);
        filename = `gemini-export-${timestamp}.json`;
        mimeType = 'application/json';
        break;
    }

    // Use the background script to trigger download
    chrome.runtime.sendMessage({
      action: 'downloadFile',
      content: content,
      filename: filename,
      mimeType: mimeType,
    });
  }

  /**
   * Reset UI to initial state.
   */
  function resetUI() {
    statusBar.classList.add('hidden');
    resultPanel.classList.add('hidden');
    mainPanel.classList.remove('hidden');
    btnExport.disabled = false;
    btnCancel.classList.add('hidden');
    progressBar.style.width = '0%';
    exportedData = null;
  }

  // Event listeners
  btnExport.addEventListener('click', startExport);

  btnCancel.addEventListener('click', () => {
    exportCancelled = true;
    statusText.textContent = '正在取消...';
  });

  btnDownload.addEventListener('click', downloadExport);
  btnBack.addEventListener('click', resetUI);

  // Listen for progress updates from content script
  chrome.runtime.onMessage.addListener((message) => {
    if (message.action === 'exportProgress') {
      const { current, total, title } = message.progress;
      updateProgress(current, total, title);
    }
  });

  // Initialize
  checkPage();
})();
