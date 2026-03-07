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
    const clone = element.cloneNode(true);

    const codeEls = clone.querySelectorAll('pre, code-block, .code-block');
    for (const el of codeEls) {
      el.remove();
    }

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

    const titleEl =
      document.querySelector('h1.conversation-title') ||
      document.querySelector('[class*="conversation-title"]') ||
      document.querySelector('[data-conversation-title]') ||
      document.title;

    conversation.title =
      typeof titleEl === 'string'
        ? titleEl.replace(' - Google Gemini', '').trim()
        : titleEl?.textContent?.trim() || document.title.replace(' - Google Gemini', '').trim();

    const messageSelectors = [
      'message-content',
      '.conversation-container .message',
      '[class*="message-content"]',
      '[class*="query-content"], [class*="response-content"]',
      '[class*="user-query"], [class*="model-response"]',
      'user-query, model-response',
      '.query-text, .response-text',
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

    if (messageElements.length === 0) {
      const mainContent =
        document.querySelector('[class*="conversation"]') ||
        document.querySelector('main') ||
        document.querySelector('[role="main"]');

      if (mainContent) {
        const allChildren = mainContent.querySelectorAll(
          '[class*="query"], [class*="response"], [class*="prompt"], [class*="answer"]'
        );
        if (allChildren.length > 0) {
          messageElements = Array.from(allChildren);
        }
      }
    }

    for (const el of messageElements) {
      const classList = Array.from(el.classList || []);
      const tagName = el.tagName?.toLowerCase() || '';

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

  // Listen for messages from the popup
  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message.action === 'checkPage') {
      sendResponse({
        isGemini: window.location.hostname.includes('gemini.google.com'),
      });
      // Synchronous response — do NOT return true
      return;
    }

    if (message.action === 'exportCurrent') {
      try {
        const data = extractCurrentConversation();
        sendResponse({ success: true, data: [data] });
      } catch (err) {
        sendResponse({ success: false, error: err.message });
      }
      // Synchronous response — do NOT return true
      return;
    }

    if (message.action === 'getConversationList') {
      try {
        const list = getConversationList();
        sendResponse({ success: true, data: list });
      } catch (err) {
        sendResponse({ success: false, error: err.message });
      }
      // Synchronous response — do NOT return true
      return;
    }
  });
})();
