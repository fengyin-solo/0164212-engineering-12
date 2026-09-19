/// <reference types="vite/client" />

declare module '*.vue' {
  import type { DefineComponent } from 'vue'
  const component: DefineComponent<{}, {}, any>
  export default component
}

interface ImportMetaEnv {
  readonly VITE_APP_TITLE: string
  readonly VITE_API_BASE_URL: string
}

interface ImportMeta {
  readonly env: ImportMetaEnv
}

// 构建时由 vite.config.ts 注入的版本信息
declare const __APP_VERSION__: string
declare const __GIT_COMMIT__: string
declare const __BUILD_TIME__: string
