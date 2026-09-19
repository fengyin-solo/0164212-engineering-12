import { defineConfig, loadEnv } from 'vite'
import vue from '@vitejs/plugin-vue'
import { resolve } from 'path'
import { readFileSync } from 'fs'
import { execSync } from 'child_process'
import AutoImport from 'unplugin-auto-import/vite'
import Components from 'unplugin-vue-components/vite'
import { ElementPlusResolver } from 'unplugin-vue-components/resolvers'

// ---- 版本信息：让构建产物可对应到具体代码版本 ----
const pkg = JSON.parse(readFileSync(resolve(__dirname, 'package.json'), 'utf-8'))

function resolveGitCommit(): string {
  // 优先使用环境变量（CI / Docker 构建时通过 build-arg 注入）
  if (process.env.VITE_GIT_COMMIT) return process.env.VITE_GIT_COMMIT
  try {
    return execSync('git rev-parse --short HEAD', { stdio: ['ignore', 'pipe', 'ignore'] })
      .toString()
      .trim()
  } catch {
    return 'unknown'
  }
}

const appVersion = process.env.VITE_APP_VERSION || pkg.version
const gitCommit = resolveGitCommit()
const buildTime = new Date().toISOString()

// 端口口径与容器对外端口保持一致，统一由根目录 .env 的 PORTAL_PORT 控制
// 优先级：环境变量 > 根目录 .env > 默认 8081
const rootEnv = loadEnv('development', resolve(__dirname, '..'), '')
const portalPort = Number(process.env.PORTAL_PORT || rootEnv.PORTAL_PORT) || 8081

export default defineConfig({
  plugins: [
    vue(),
    AutoImport({
      resolvers: [ElementPlusResolver()],
      imports: ['vue', 'vue-router', 'pinia'],
      dts: 'src/auto-imports.d.ts'
    }),
    Components({
      resolvers: [ElementPlusResolver()],
      dts: 'src/components.d.ts'
    }),
    {
      // 构建时在产物根目录生成 build-meta.json，供冒烟校验与线上排查核对版本
      name: 'portal-build-meta',
      apply: 'build',
      generateBundle() {
        this.emitFile({
          type: 'asset',
          fileName: 'build-meta.json',
          source:
            JSON.stringify(
              {
                name: pkg.name,
                version: appVersion,
                commit: gitCommit,
                builtAt: buildTime
              },
              null,
              2
            ) + '\n'
        })
      }
    }
  ],
  define: {
    __APP_VERSION__: JSON.stringify(appVersion),
    __GIT_COMMIT__: JSON.stringify(gitCommit),
    __BUILD_TIME__: JSON.stringify(buildTime)
  },
  resolve: {
    alias: {
      '@': resolve(__dirname, 'src')
    }
  },
  server: {
    port: portalPort,
    strictPort: true,
    host: '0.0.0.0',
    proxy: {
      '/api': {
        target: 'http://localhost:8080',
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/api/, '')
      }
    }
  },
  preview: {
    port: portalPort,
    strictPort: true,
    host: '0.0.0.0'
  },
  css: {
    preprocessorOptions: {
      scss: {
        additionalData: `@use "@/styles/variables.scss" as *;`
      }
    }
  },
  build: {
    outDir: 'dist',
    assetsDir: 'assets',
    sourcemap: false,
    chunkSizeWarningLimit: 1500,
    rollupOptions: {
      output: {
        manualChunks: {
          vendor: ['vue', 'vue-router', 'pinia'],
          elementPlus: ['element-plus']
        }
      }
    }
  }
})
