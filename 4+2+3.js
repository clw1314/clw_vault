// ==UserScript==
// @name         423down VIP 资源获取
// @namespace    https://www.nite07.com/
// @author       Nite
// @homepageURL  https://www.nite07.com/
// @match        https://www.423down.com/*.html
// @connect      423.nite07.com
// @connect      *.nite07.com
// @grant        GM_xmlhttpRequest
// @run-at       document-end
// @version      1.1.0
// @license MIT
// ==/UserScript==

(function () {
  "use strict";

  const API_ORIGIN = "https://423.nite07.com";
  const ARTICLE_PATH_RE = /^\/(\d+)\.html$/;

  const articleID = getArticleID(window.location.pathname);
  if (!articleID) {
    return;
  }

  replaceArticleHTML(articleID);

  function getArticleID(pathname) {
    const match = pathname.match(ARTICLE_PATH_RE);
    return match ? match[1] : "";
  }

  function replaceArticleHTML(articleID) {
    requestArticleHTML(articleID)
      .then((html) => {
        const contentDiv = document.querySelector("div.content");
        if (!contentDiv) {
          console.warn("[423down-proxy] 未找到正文容器，无法替换 HTML");
          return;
        }

        // 移除已有的 meta（标题）和 entry（正文），避免重复
        contentDiv
          .querySelectorAll("div.meta, div.entry")
          .forEach((el) => el.remove());

        // 移除第一个子元素（付费墙占位 div，无 class）
        const firstChild = contentDiv.firstElementChild;
        if (firstChild && firstChild.tagName === "DIV" && !firstChild.className) {
          firstChild.remove();
        }

        // 在 content 开头插入服务端返回的完整 HTML（含标题+正文）
        contentDiv.insertAdjacentHTML("afterbegin", html);
        console.info(`[423down-proxy] 已替换文章 ${articleID} 的正文 HTML`);
      })
      .catch((error) => {
        console.error("[423down-proxy] 获取文章 HTML 失败：", error);
      });
  }

  function requestArticleHTML(articleID) {
    const url = `${API_ORIGIN}/?article_id=${encodeURIComponent(articleID)}`;

    return new Promise((resolve, reject) => {
      GM_xmlhttpRequest({
        method: "GET",
        url,
        responseType: "json",
        timeout: 30_000,
        onload(response) {
          if (response.status < 200 || response.status >= 300) {
            reject(new Error(`HTTP ${response.status}`));
            return;
          }

          const data = parseResponse(response);
          if (!data || data.ok !== true || typeof data.html !== "string") {
            reject(
              new Error(data && data.error ? data.error : "接口响应格式不正确"),
            );
            return;
          }

          resolve(data.html);
        },
        onerror() {
          reject(new Error("网络请求失败"));
        },
        ontimeout() {
          reject(new Error("网络请求超时"));
        },
      });
    });
  }

  function parseResponse(response) {
    if (response.response && typeof response.response === "object") {
      return response.response;
    }

    try {
      return JSON.parse(response.responseText);
    } catch (error) {
      console.error("[423down-proxy] JSON 解析失败：", error);
      return null;
    }
  }
})();

==UserScript== // @name 423down VIP 资源获取 // @namespace https://www.nite07.com/ // @author Nite // @homepageURL https://www.nite07.com/ // @match https：//www.423down.com/*.html // @connect 423.nite07.com // @connect *.nite07.com // @grant GM_xmlhttpRequest // @run-at document-end // @version 1.1.0 // @license MIT // ==/UserScript== （函数 （） { “use strict”; const API_ORIGIN = “https://423.nite07.com”; const ARTICLE_PATH_RE = /^/（\d+）.html/; const articleID = getArticleID（window.location.路径名）;if （！articleID） { return; } replaceArticleHTML（articleID）;function getArticleID（pathname） { const match = pathname.match（ARTICLE_PATH_RE）; return match ？ match[1] ： “”; }function replaceArticleHTML（articleID） { requestArticleHTML（articleID） .then（html） => { const contentDiv = document.querySelector（“div.content”）; if （！contentDiv） { console.warn（“[423down-proxy] 未找到正文容器，无法替换 HTML”）; return; } // 移除已有的 meta（标题）和 entry（正文），避免重复 contentDiv .querySelectorAll（“div.meta， div.entry”） .forEach（（el） => el.remove（））; // 移除第一个子元素（付费墙占位 div，无 class） const firstChild = contentDiv.firstElementChild; if （firstChild && firstChild.tagName === “DIV” && ！firstChild.className） { firstChild.remove（）; } // 在 content 开头插入服务端返回的完整 HTML（含标题+正文） contentDiv.insertAdjacentHTML（“afterbegin”， html）;console.info（'[423down-proxy] 已替换文章 {articleID} 的正文 HTML'）;}） .catch（（error） => { console.error（“[423down-proxy] 获取文章 HTML 失败：”， error）; }）;} 函数 requestArticleHTML（articleID） { cont url = 'APIORIGIN/？articleid=
APIO​RIGIN/？articlei​d={encodeURIComponent（articleID）}'; return new Promise（（resolve， reject） => { GM_xmlhttpRequest（{ 方法：“GET”， url， responseType： “json”， timeout： 30_000， onload（response） { if （response.status < 200 || response.status >= 300） { reject（new Error（'HTTP ${response.status}'））; return; } const data = parseResponse（response）; if （！data || data.ok ！== true || typeof data.html ！== “string”） { reject（ new Error（data && data.error？data.error ： “接口响应格式不正确”），）;返回;} resolve（data.html）;}， onerror（） { reject（new Error（“网络请求失败”））; }， ontimeout（） { reject（new Error（“网络请求超时”））; }， }）;});} 函数 parseResponse（response） { if （response.response && typeof response.response === “object”） { return response.response; } try { return JSON.parse（response.responseText）; } catch （error） { console.error（“[423down-proxy] JSON 解析失败：”， error;return null;} } }）();

