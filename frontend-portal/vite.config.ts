import { defineConfig, type Plugin } from 'vite'
import vue from '@vitejs/plugin-vue'
import { resolve } from 'path'
import { readFileSync, existsSync } from 'fs'
import AutoImport from 'unplugin-auto-import/vite'
import Components from 'unplugin-vue-components/vite'
import { ElementPlusResolver } from 'unplugin-vue-components/resolvers'

// dev / preview 内置 /healthz，与容器内 nginx 的存活探针保持一致
function healthzPlugin(): Plugin {
  const middleware = (req: any, res: any, next: () => void) => {
    if (req.url === '/healthz') {
      res.statusCode = 200
      res.setHeader('Content-Type', 'text/plain')
      res.end('ok\n')
      return
    }
    next()
  }
  return {
    name: 'dev-healthz',
    configureServer(server) {
      server.middlewares.use(middleware)
    },
    configurePreviewServer(server) {
      server.middlewares.use(middleware)
    }
  }
}

// 统一端口来源：仓库根目录 .env（与 docker-compose 读取同一个文件）
const rootEnv = resolve(__dirname, '../.env')
function loadRootEnv(): Record<string, string> {
  if (!existsSync(rootEnv)) return {}
  const env: Record<string, string> = {}
  for (const line of readFileSync(rootEnv, 'utf-8').split('\n')) {
    const m = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$/)
    if (m) env[m[1]] = m[2].replace(/^["']|["']$/g, '')
  }
  return env
}
const rootEnvVars = loadRootEnv()
const PORT = Number(process.env.PORT || rootEnvVars.PORT || 8081)
const BACKEND_URL =
  process.env.BACKEND_URL || rootEnvVars.BACKEND_URL || 'http://localhost:8080'

// 与 docker-compose、本地开发共用同一套 /api 代理规则：去掉 /api 前缀后转发
const apiProxy = {
  '/api': {
    target: BACKEND_URL,
    changeOrigin: true,
    rewrite: (path: string) => path.replace(/^\/api/, '')
  }
}

export default defineConfig({
  plugins: [
    healthzPlugin(),
    vue(),
    AutoImport({
      resolvers: [ElementPlusResolver()],
      imports: ['vue', 'vue-router', 'pinia'],
      dts: 'src/auto-imports.d.ts'
    }),
    Components({
      resolvers: [ElementPlusResolver()],
      dts: 'src/components.d.ts'
    })
  ],
  resolve: {
    alias: {
      '@': resolve(__dirname, 'src')
    }
  },
  server: {
    port: PORT,
    strictPort: true, // 端口被占用直接失败，而不是悄悄换端口，避免口径不一致
    host: '0.0.0.0',
    proxy: apiProxy
  },
  preview: {
    port: PORT,
    strictPort: true,
    host: '0.0.0.0',
    proxy: apiProxy
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
