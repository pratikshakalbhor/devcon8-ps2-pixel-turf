import { useState, useEffect, useRef, useMemo, useCallback } from 'react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { WagmiProvider, createConfig, useAccount, useConnect, useChainId, useDisconnect, useReadContract, useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { baseSepolia } from 'wagmi/chains'
import { injected, coinbaseWallet } from 'wagmi/connectors'
import { http, getAddress, isAddress, decodeEventLog, type Log } from 'viem'
import { createPublicClient } from 'viem'
import PixelTurfABI from '../abi/PixelTurf.json'
import './styles.css'

const queryClient = new QueryClient()

const CONTRACT_ADDRESS = import.meta.env.VITE_PIXELTURF_ADDRESS || '0x0000000000000000000000000000000000000000'
const DEPLOYMENT_BLOCK = BigInt(import.meta.env.VITE_DEPLOYMENT_BLOCK || '0')
const RPC_URL = import.meta.env.VITE_RPC_URL || 'https://sepolia.base.org'

const publicClient = createPublicClient({
  chain: baseSepolia,
  transport: http(RPC_URL),
})

const config = createConfig({
  chains: [baseSepolia],
  connectors: [
    injected(),
    coinbaseWallet({
      appName: 'PixelTurf',
      appLogoUrl: undefined,
    }),
  ],
  transports: {
    [baseSepolia.id]: http(RPC_URL),
  },
})

const WIDTH = 64
const HEIGHT = 64
const TILE_SIZE = 10
const PALETTE_SIZE = 16

const PALETTE_COLORS = [
  '#FFFFFF', // 0 - blank/white (never painted)
  '#1A1A1A', // 1
  '#FF0000', // 2
  '#FF7F00', // 3
  '#FFFF00', // 4
  '#00FF00', // 5
  '#00FFFF', // 6
  '#0000FF', // 7
  '#7F00FF', // 8
  '#FF00FF', // 9
  '#808080', // 10
  '#C0C0C0', // 11
  '#8B4513', // 12
  '#00FF7F', // 13
  '#4B0082', // 14
  '#FF69B4', // 15
]

function indexFromXY(x: number, y: number): number {
  return y * WIDTH + x
}

function makeEmptyCanvas(): Uint8Array {
  return new Uint8Array(WIDTH * HEIGHT)
}

function bytesToCanvas(data: string | Uint8Array): Uint8Array {
  const bytes = typeof data === 'string' ? new Uint8Array(Buffer.from(data.slice(2), 'hex')) : data
  const canvas = makeEmptyCanvas()
  const len = Math.min(bytes.length, canvas.length)
  for (let i = 0; i < len; i++) {
    canvas[i] = bytes[i]
  }
  return canvas
}

function extractLogBlock(log: any): bigint | undefined {
  if (typeof log === 'object' && log !== null && 'blockNumber' in log && log.blockNumber) {
    return BigInt(log.blockNumber)
  }
  return undefined
}

function formatCooldown(nextAllowedAt: bigint, now: bigint): { seconds: number; remaining: string; canPaint: boolean } {
  if (now >= nextAllowedAt) {
    return { seconds: 0, remaining: '0s', canPaint: true }
  }
  const diff = Number(nextAllowedAt - now)
  const s = Math.ceil(diff / 1000) || 0
  return { seconds: s, remaining: `${s}s`, canPaint: false }
}

function prettyRevert(err: unknown): string {
  const msg = (err as any)?.message || String(err)
  if (msg.includes('CooldownActive')) return 'Still cooling down. Wait for your cooldown to finish.'
  if (msg.includes('OutOfBounds')) return 'Coordinates are out of bounds.'
  if (msg.includes('InvalidColor')) return 'Invalid color selected.'
  if (msg.includes('User rejected') || msg.includes('rejected')) return 'Transaction rejected by user.'
  return msg.length > 120 ? msg.slice(0, 120) + '...' : msg
}

function InnerApp() {
  const { address, isConnected } = useAccount()
  const chainId = useChainId()
  const { connect, connectors, status } = useConnect()
  const { disconnect } = useDisconnect()

  const [canvas, setCanvas] = useState<Uint8Array>(() => makeEmptyCanvas())
  const [selectedColor, setSelectedColor] = useState<number>(1)
  const [selectedX, setSelectedX] = useState<number | null>(null)
  const [selectedY, setSelectedY] = useState<number | null>(null)
  const [lastProcessedBlock, setLastProcessedBlock] = useState<bigint>(DEPLOYMENT_BLOCK)
  const [statusMessage, setStatusMessage] = useState<string>('')
  const [now, setNow] = useState<number>(() => Date.now())
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const hoverRef = useRef<HTMLCanvasElement>(null)

  const { data: width } = useReadContract({ address: CONTRACT_ADDRESS as `0x${string}`, abi: PixelTurfABI as any, functionName: 'WIDTH' })
  const { data: height } = useReadContract({ address: CONTRACT_ADDRESS as `0x${string}`, abi: PixelTurfABI as any, functionName: 'HEIGHT' })
  const { data: cooldownSecs } = useReadContract({ address: CONTRACT_ADDRESS as `0x${string}`, abi: PixelTurfABI as any, functionName: 'COOLDOWN' })
  const { data: nextAllowedAt } = useReadContract({
    address: CONTRACT_ADDRESS as `0x${string}`,
    abi: PixelTurfABI as any,
    functionName: 'nextAllowedAt',
    args: address && isAddress(address) ? [getAddress(address)] : undefined,
    query: { enabled: !!(address && isAddress(address)) },
  })

  const { writeContract, data: txHash, error: writeError, isPending } = useWriteContract()
  const { isLoading: isConfirming, isSuccess: isConfirmed } = useWaitForTransactionReceipt({ hash: txHash })

  const nextAllowedAtBig = useMemo(() => (nextAllowedAt ? BigInt(nextAllowedAt) : BigInt(0)), [nextAllowedAt])
  const cooldownRemaining = useMemo(() => formatCooldown(nextAllowedAtBig, BigInt(Math.floor(now / 1000)) * BigInt(1) === nextAllowedAtBig ? BigInt(now) : BigInt(Math.floor(now / 1000)) * BigInt(1) ? BigInt(Math.floor(now / 1000)) * BigInt(1) : BigInt(now) >= nextAllowedAtBig ? BigInt(Math.floor(now / 1000)) * BigInt(1) : BigInt(now)), [nextAllowedAtBig, now])
  const canPaint = cooldownRemaining.canPaint && !isPending && !isConfirming

  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 500)
    return () => clearInterval(id)
  }, [])

  useEffect(() => {
    if (!canvasRef.current) return
    const ctx = canvasRef.current.getContext('2d')
    if (!ctx) return
    ctx.imageSmoothingEnabled = false
    for (let y = 0; y < HEIGHT; y++) {
      for (let x = 0; x < WIDTH; x++) {
        const c = canvas[indexFromXY(x, y)] % PALETTE_SIZE
        ctx.fillStyle = PALETTE_COLORS[c] || PALETTE_COLORS[0]
        ctx.fillRect(x * TILE_SIZE, y * TILE_SIZE, TILE_SIZE, TILE_SIZE)
      }
    }
  }, [canvas])

  useEffect(() => {
    if (!hoverRef.current) return
    const ctx = hoverRef.current.getContext('2d')
    if (!ctx) return
    ctx.clearRect(0, 0, WIDTH * TILE_SIZE, HEIGHT * TILE_SIZE)
    if (selectedX !== null && selectedY !== null) {
      ctx.strokeStyle = '#00FFFF'
      ctx.lineWidth = 2
      ctx.strokeRect(selectedX * TILE_SIZE + 1, selectedY * TILE_SIZE + 1, TILE_SIZE - 2, TILE_SIZE - 2)
    }
  }, [selectedX, selectedY])

  const loadInitialCanvas = useCallback(async () => {
    try {
      setStatusMessage('Loading canvas...')
      const result = await publicClient.readContract({
        address: CONTRACT_ADDRESS as `0x${string}`,
        abi: PixelTurfABI as any,
        functionName: 'getCanvas',
      })
      const loaded = bytesToCanvas(result as any)
      setCanvas(loaded)
      setLastProcessedBlock(DEPLOYMENT_BLOCK)
      setStatusMessage('Canvas loaded')
    } catch (e) {
      console.error('Failed to load canvas:', e)
      setStatusMessage('Failed to load canvas via getCanvas; falling back')
    }
  }, [])

  const fetchNewLogs = useCallback(async () => {
    try {
      const fromBlock = lastProcessedBlock + BigInt(1)
      const toBlock = 'latest' as const
      const logs = await publicClient.getLogs({
        address: CONTRACT_ADDRESS as `0x${string}`,
        event: {
          type: 'event',
          name: 'TilePlaced',
          inputs: [
            { type: 'address', name: 'player', indexed: true },
            { type: 'uint16', name: 'x', indexed: false },
            { type: 'uint16', name: 'y', indexed: false },
            { type: 'uint8', name: 'color', indexed: false },
          ],
        } as any,
        fromBlock,
        toBlock,
      })
      if (logs.length > 0) {
        setCanvas((prev) => {
          const next = new Uint8Array(prev)
          let maxBlock = lastProcessedBlock
          for (const log of logs) {
            const b = extractLogBlock(log)
            if (b && b > maxBlock) maxBlock = b
            try {
              const decoded = decodeEventLog({ abi: PixelTurfABI as any, data: log.data, topics: log.topics })
              if (decoded.eventName === 'TilePlaced') {
                const { x, y, color } = decoded.args as any
                const nx = Number(x)
                const ny = Number(y)
                if (nx >= 0 && nx < WIDTH && ny >= 0 && ny < HEIGHT) {
                  next[indexFromXY(nx, ny)] = Number(color) & 0xff
                }
              }
            } catch (err) {
              console.error('Failed to decode log:', err)
            }
          }
          setLastProcessedBlock(maxBlock)
          return next
        })
      }
    } catch (e) {
      console.error('Failed to fetch logs:', e)
    }
  }, [lastProcessedBlock])

  useEffect(() => {
    loadInitialCanvas()
  }, [loadInitialCanvas])

  useEffect(() => {
    const id = setInterval(() => {
      fetchNewLogs()
    }, 3000)
    return () => clearInterval(id)
  }, [fetchNewLogs])

  useEffect(() => {
    if (isConfirmed) {
      setStatusMessage('Tile placed successfully!')
      fetchNewLogs()
    }
    if (writeError) {
      setStatusMessage(prettyRevert(writeError))
    }
  }, [isConfirmed, writeError, fetchNewLogs])

  const handleCanvasClick = useCallback((e: React.MouseEvent<HTMLCanvasElement>) => {
    const rect = e.currentTarget.getBoundingClientRect()
    const mx = e.clientX - rect.left
    const my = e.clientY - rect.top
    const x = Math.floor(mx / TILE_SIZE)
    const y = Math.floor(my / TILE_SIZE)
    if (x >= 0 && x < WIDTH && y >= 0 && y < HEIGHT) {
      setSelectedX(x)
      setSelectedY(y)
    }
  }, [])

  const handleCanvasMove = useCallback((e: React.MouseEvent<HTMLCanvasElement>) => {
    const rect = e.currentTarget.getBoundingClientRect()
    const mx = e.clientX - rect.left
    const my = e.clientY - rect.top
    const x = Math.floor(mx / TILE_SIZE)
    const y = Math.floor(my / TILE_SIZE)
    if (x >= 0 && x < WIDTH && y >= 0 && y < HEIGHT) {
      if (hoverRef.current) {
        const ctx = hoverRef.current.getContext('2d')
        if (ctx) {
          ctx.clearRect(0, 0, WIDTH * TILE_SIZE, HEIGHT * TILE_SIZE)
          ctx.strokeStyle = 'rgba(0,255,255,0.5)'
          ctx.lineWidth = 1
          ctx.strokeRect(x * TILE_SIZE, y * TILE_SIZE, TILE_SIZE, TILE_SIZE)
        }
      }
    }
  }, [])

  const handlePaint = useCallback(() => {
    if (selectedX === null || selectedY === null) {
      setStatusMessage('Select a tile to paint')
      return
    }
    if (!address || !isConnected) {
      setStatusMessage('Connect a wallet to paint')
      return
    }
    setStatusMessage('Submitting transaction...')
    writeContract({
      address: CONTRACT_ADDRESS as `0x${string}`,
      abi: PixelTurfABI as any,
      functionName: 'placeTile',
      args: [selectedX, selectedY, selectedColor],
    })
  }, [selectedX, selectedY, selectedColor, address, isConnected, writeContract])

  return (
    <div className="app">
      <header>
        <h1>PixelTurf</h1>
        <div style={{ fontSize: 12, opacity: 0.7 }}>64x64 Canvas • Base Sepolia</div>
      </header>

      <div className="controls">
        <div>
          {isConnected && address ? (
            <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
              <span style={{ fontSize: 12 }}>{address.slice(0, 6)}...{address.slice(-4)}</span>
              <button onClick={() => disconnect()}>Disconnect</button>
            </div>
          ) : (
            <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', justifyContent: 'center' }}>
              {connectors.map((connector) => (
                <button key={connector.uid} onClick={() => connect({ connector })} disabled={status === 'pending'}>
                  {connector.name}
                </button>
              ))}
            </div>
          )}
        </div>

        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 4 }}>
          <div className="countdown">
            {address && isConnected
              ? cooldownRemaining.canPaint
                ? 'You can paint now'
                : `You can paint again in ${cooldownRemaining.remaining}`
              : 'Connect wallet to see cooldown'}
          </div>
          {cooldownSecs !== undefined && <div style={{ fontSize: 10, opacity: 0.6 }}>Cooldown: {String(cooldownSecs)}s</div>}
        </div>

        <div className="palette">
          {Array.from({ length: PALETTE_SIZE }).map((_, i) => (
            <button
              key={i}
              className={`color-swatch ${selectedColor === i ? 'selected' : ''}`}
              style={{ background: PALETTE_COLORS[i] || '#FFFFFF' }}
              onClick={() => setSelectedColor(i)}
              title={`Color ${i}`}
            />
          ))}
        </div>

        <button onClick={handlePaint} disabled={!isConnected || !canPaint || selectedX === null || selectedY === null}>
          {isPending || isConfirming ? 'Painting...' : 'Paint'}
        </button>

        <div style={{ display: 'flex', flexDirection: 'column', gap: 2, fontSize: 12, alignItems: 'center' }}>
          <div>Selected: {selectedX !== null && selectedY !== null ? `(${selectedX}, ${selectedY})` : 'None'}</div>
          {CONTRACT_ADDRESS && CONTRACT_ADDRESS !== '0x0000000000000000000000000000000000000000' && (
            <a href={`https://sepolia.basescan.org/address/${CONTRACT_ADDRESS}`} target="_blank" rel="noreferrer" style={{ color: '#60A5FA' }}>
              View on Basescan
            </a>
          )}
        </div>
      </div>

      {chainId !== baseSepolia.id && isConnected && (
        <div style={{ padding: 8, background: '#7C1C2B', borderRadius: 8, fontSize: 14 }}>Switch to Base Sepolia to paint</div>
      )}

      <div className="canvas-wrapper">
        <div style={{ position: 'relative' }}>
          <canvas ref={canvasRef} width={WIDTH * TILE_SIZE} height={HEIGHT * TILE_SIZE} className="canvas" onClick={handleCanvasClick} onMouseMove={handleCanvasMove} />
          <canvas ref={hoverRef} width={WIDTH * TILE_SIZE} height={HEIGHT * TILE_SIZE} style={{ position: 'absolute', top: 0, left: 0, pointerEvents: 'none' }} />
        </div>
        <div className="status">{statusMessage}</div>
      </div>
    </div>
  )
}

export default function App() {
  return (
    <WagmiProvider config={config}>
      <QueryClientProvider client={queryClient}>
        <InnerApp />
      </QueryClientProvider>
    </WagmiProvider>
  )
}
