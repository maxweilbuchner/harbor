// Loaded with <script defer> from the page's head: must run after the page is parsed, so after the inline script
// at the end of the body, and with the element after it in the document.
window.deferOk = window.inlineRan === true && !!document.getElementById("root");
