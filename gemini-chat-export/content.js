/**
 * Gemini Chat Export - Content Script
 * Extracts conversation data from the Gemini web interface.
 *
 * Gemini's DOM structure is dynamic and uses Angular-based components.
 * This script traverses the rendered DOM to extract messages, code blocks,
 * and embedded media/attachments.
 */

(function () {
  'use strict';

  /**
   * Extract all image sources from a message element.
   */
  function extractImages(element) {
    const images = [];
    const imgElements = element.querySelectorAll('img');
    for (const img of imgElements) {
      const src = img.src || img.getAttribute('data-src');
      if (src && !src.includes('avatar') && !src.includes('icon') && !src.includes('logo')) {
        images.push({
          type: 'image',
          src: src,
          alt: img.alt || '',
          width: img.naturalWidth || img.width,
          height: img.naturalHeight || img.height,
        });
      }
    }
    return images;
  }

  /**
   * Extract code blocks from a message element.
   */
  function extractCodeBlocks(element) {
    const codeBlocks = [];
    // Gemini wraps code in <code-block> custom elements or pre>code
    const preElements = element.querySelectorAll('pre code, code-block, .code-block');
    for (const pre of preElements) {
      const languageEl = pre.closest('[class*="language-"]') || pre;
      const classList = Array.from(languageEl.classList || []);
      const langClass = classList.find(c => c.startsWith('language-'));
      const language = langClass ? langClass.replace('language-', '') : 'plaintext';
      codeBlocks.push({
        language: language,
        code: pre.textContent || '',
      });
    }
    return codeBlocks;
  }

  /**
   * Extract file attachments (uploaded files shown in the conversation).
   */
  function extractAttachments(element) {
    const attachments = [];

    // Look for file upload indicators / attachment chips
    const fileChips = element.querySelectorAll(
      '[class*="attachment"], [class*="file-chip"], [class*="uploaded-file"], [data-file-name]'
    );
    for (const chip of fileChips) {
      const fileName =
        chip.getAttribute('data-file-name') ||
        chip.querySelector('[class*="file-name"], .name')?.textContent?.trim() ||
        chip.textContent?.trim();
      if (fileName) {
        attachments.push({
          type: 'file',
          name: fileName,
        });
      }
    }

    // Look for download links
    const links = element.querySelectorAll('a[download], a[href*="blob:"], a[href*="data:"]');
    for (const link of links) {
      attachments.push({
        type: 'download_link',
        name: link.download || link.textContent?.trim() || 'unknown',
        url: link.href,
      });
    }

    return attachments;
  }

  /**
   * Get the text content of a message, preserving structure.
   */
  function getMessageText(element) {
    // Clone to avoid modifying the real DOM
    const clone = element.cloneNode(true);

    // Remove code blocks from text extraction (they're captured separately)
    const codeEls = clone.querySelectorAll('pre, code-block, .code-block');
    for (const el of codeEls) {
      el.remove();
    }

    // Convert common formatting elements
    const bolds = clone.querySelectorAll('b, strong');
    for (const b of bolds) {
      b.textContent = `**${b.textContent}**`;
    }
    const italics = clone.querySelectorAll('i, em');
    for (const i of italics) {
      i.textContent = `*${i.textContent}*`;
    }

    return clone.textContent?.trim() || '';
  }

  /**
   * Extract the current conversation visible on the page.
   */
  function extractCurrentConversation() {
    const conversation = {
      title: '',
      url: window.location.href,
      timestamp: new Date().toISOString(),
      messages: [],
    };

    // Try to get the conversation title
    const titleEl =
      document.querySelector('h1.conversation-title') ||
      document.querySelector('[class*="conversation-title"]') ||
      document.querySelector('[data-conversation-title]') ||
      document.title;

    conversation.title =
      typeof titleEl === 'string' ? titleEl.replace(' - Google Gemini', '').trim() : titleEl?.textContent?.trim() || document.title.replace(' - Google Gemini', '').trim();

    // Gemini conversation containers - try multiple selectors
    // The DOM structure may change, so we use broad selectors
    const messageSelectors = [
      // Common Gemini message containers
      'message-content',
      '.conversation-container .message',
      '[class*="message-content"]',
      '[class*="query-content"], [class*="response-content"]',
      '[class*="user-query"], [class*="model-response"]',
      // Fallback: Angular-based selectors
      'user-query, model-response',
      '.query-text, .response-text',
      // Generic turn containers
      '[class*="turn"]',
      '[class*="chat-turn"]',
    ];

    let messageElements = [];
    for (const selector of messageSelectors) {
      try {
        const elements = document.querySelectorAll(selector);
        if (elements.length > 0) {
          messageElements = Array.from(elements);
          break;
        }
      } catch (e) {
        // Invalid selector, skip
      }
    }

    // If no specific message containers found, try to parse the conversation
    // by looking at the main content area structure
    if (messageElements.length === 0) {
      // Try to find conversation turns by traversing the main content
      const mainContent =
        document.querySelector('[class*="conversation"]') ||
        document.querySelector('main') ||
        document.querySelector('[role="main"]');

      if (mainContent) {
        // Look for alternating user/model message patterns
        const allChildren = mainContent.querySelectorAll('[class*="query"], [class*="response"], [class*="prompt"], [class*="answer"]');
        if (allChildren.length > 0) {
          messageElements = Array.from(allChildren);
        }
      }
    }

    // Parse each message element
    for (const el of messageElements) {
      const classList = Array.from(el.classList || []);
      const tagName = el.tagName?.toLowerCase() || '';

      // Determine the role (user or model)
      const isUser =
        classList.some(c => /user|query|prompt|human/i.test(c)) ||
        tagName.includes('query') ||
        tagName.includes('user');

      const role = isUser ? 'user' : 'model';

      const message = {
        role: role,
        text: getMessageText(el),
        codeBlocks: extractCodeBlocks(el),
        images: extractImages(el),
        attachments: extractAttachments(el),
      };

      // Only add messages with actual content
      if (message.text || message.codeBlocks.length > 0 || message.images.length > 0 || message.attachments.length > 0) {
        conversation.messages.push(message);
      }
    }

    return conversation;
  }

  /**
   * Get the list of all conversations from the sidebar.
   */
  function getConversationList() {
    const conversations = [];
    const sidebarSelectors = [
      '[class*="conversation-list"] a',
      '[class*="chat-list"] a',
      '[class*="sidebar"] a[href*="/chat/"]',
      '[class*="history"] a',
      'nav a[href*="/chat/"]',
      'a[href*="/app/"]',
    ];

    let links = [];
    for (const selector of sidebarSelectors) {
      try {
        const elements = document.querySelectorAll(selector);
        if (elements.length > 0) {
          links = Array.from(elements);
          break;
        }
      } catch (e) {
        // skip
      }
    }

    for (const link of links) {
      const title = link.textContent?.trim();
      const url = link.href;
      if (title && url) {
        conversations.push({ title, url });
      }
    }

    return conversations;
  }

  /**
   * Navigate to a conversation URL and wait for it to load.
   */
  function navigateAndWait(url) {
    return new Promise((resolve) => {
      window.location.href = url;
      // Wait for the page to load and render
      const checkReady = setInterval(() => {
        const messages = document.querySelectorAll(
          '[class*="message"], [class*="query"], [class*="response"], [class*="turn"]'
        );
        if (messages.length > 0) {
          clearInterval(checkReady);
          // Extra wait for dynamic content to fully render
          setTimeout(resolve, 1500);
        }
      }, 500);
      // Timeout after 15 seconds
      setTimeout(() => {
        clearInterval(checkReady);
        resolve();
      }, 15000);
    });
  }

  /**
   * Export all conversations by iterating through the sidebar list.
   */
  async function exportAllConversations(options, sendProgress) {
    const conversationList = getConversationList();
    const allConversations = [];

    if (conversationList.length === 0) {
      // If we can't find a list, just export the current one
      sendProgress({ current: 1, total: 1, title: 'Current conversation' });
      allConversations.push(extractCurrentConversation());
    } else {
      const originalUrl = window.location.href;

      for (let i = 0; i < conversationList.length; i++) {
        const conv = conversationList[i];
        sendProgress({
          current: i + 1,
          total: conversationList.length,
          title: conv.title,
        });

        await navigateAndWait(conv.url);
        const data = extractCurrentConversation();
        data.title = conv.title || data.title;
        allConversations.push(data);

        // Small delay between navigations
        await new Promise(r => setTimeout(r, 500));
      }

      // Navigate back to original page
      window.location.href = originalUrl;
    }

    return allConversations;
  }

  // Listen for messages from the popup
  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message.action === 'checkPage') {
      sendResponse({
        isGemini: window.location.hostname.includes('gemini.google.com'),
      });
      return true;
    }

    if (message.action === 'exportCurrent') {
      try {
        const data = extractCurrentConversation();
        sendResponse({ success: true, data: [data] });
      } catch (err) {
        sendResponse({ success: false, error: err.message });
      }
      return true;
    }

    if (message.action === 'getConversationList') {
      try {
        const list = getConversationList();
        sendResponse({ success: true, data: list });
      } catch (err) {
        sendResponse({ success: false, error: err.message });
      }
      return true;
    }

    if (message.action === 'exportAll') {
      (async () => {
        try {
          const data = await exportAllConversations(message.options, (progress) => {
            chrome.runtime.sendMessage({
              action: 'exportProgress',
              progress: progress,
            });
          });
          sendResponse({ success: true, data: data });
        } catch (err) {
          sendResponse({ success: false, error: err.message });
        }
      })();
      return true; // Keep message channel open for async
    }

    if (message.action === 'exportConversationAt') {
      (async () => {
        try {
          await navigateAndWait(message.url);
          const data = extractCurrentConversation();
          data.title = message.title || data.title;
          sendResponse({ success: true, data: data });
        } catch (err) {
          sendResponse({ success: false, error: err.message });
        }
      })();
      return true;
    }
  });
})();
