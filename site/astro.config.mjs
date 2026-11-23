import { defineConfig } from "astro/config";

// Served from GitHub Pages under the repository's path. A custom domain later means
// changing these two values and nothing else: every internal link goes through withBase().
export default defineConfig({
  site: "https://maxweilbuchner.github.io",
  base: "/harbor",
  trailingSlash: "always",
});
