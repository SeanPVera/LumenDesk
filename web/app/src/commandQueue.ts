/** Run commands to one fixture in order, retaining only the latest queued
 * value for a continuous control. A command already sent is never replaced. */
export type CommandOutcome<T> =
  | { ok: true; value: T }
  | { ok: false; error: unknown; cancelled?: boolean }

type Job<Kind, Result> = {
  kind: Kind
  execute: () => Promise<Result>
  resolve: Array<(outcome: CommandOutcome<Result>) => void>
}

type Queue<Kind, Result> = {
  pending: Job<Kind, Result>[]
  active: Job<Kind, Result> | null
  running: boolean
  cancelled: boolean
}

export class DeviceCommandQueue<Kind, Result> {
  private queues = new Map<string, Queue<Kind, Result>>()

  has(deviceID: string): boolean {
    return this.queues.has(deviceID)
  }

  /** Release callers immediately. An already sent request may still settle,
   * but its old drain cannot run unsent work or remove a replacement queue. */
  cancelAll(): void {
    const outcome: CommandOutcome<Result> = {
      ok: false, error: new Error('The bridge connection changed.'), cancelled: true,
    }
    for (const queue of this.queues.values()) {
      queue.cancelled = true
      if (queue.active) this.settle(queue.active, outcome)
      queue.pending.forEach(job => this.settle(job, outcome))
      queue.pending.length = 0
    }
    this.queues.clear()
  }

  enqueue(deviceID: string, kind: Kind, execute: () => Promise<Result>, coalesce = false): Promise<CommandOutcome<Result>> {
    return new Promise(resolve => {
      let queue = this.queues.get(deviceID)
      if (!queue) {
        queue = { pending: [], active: null, running: false, cancelled: false }
        this.queues.set(deviceID, queue)
      }

      const last = queue.pending.at(-1)
      if (coalesce && last?.kind === kind) {
        last.execute = execute
        last.resolve.push(resolve)
      } else {
        queue.pending.push({ kind, execute, resolve: [resolve] })
      }

      if (!queue.running) void this.drain(deviceID, queue)
    })
  }

  private settle(job: Job<Kind, Result>, outcome: CommandOutcome<Result>): void {
    job.resolve.forEach(resolve => resolve(outcome))
    job.resolve.length = 0
  }

  private async drain(deviceID: string, queue: Queue<Kind, Result>): Promise<void> {
    queue.running = true
    while (!queue.cancelled && queue.pending.length) {
      const job = queue.pending.shift()!
      queue.active = job
      let outcome: CommandOutcome<Result>
      try {
        outcome = { ok: true, value: await job.execute() }
      } catch (error) {
        outcome = { ok: false, error }
      }
      if (!queue.cancelled) this.settle(job, outcome)
      queue.active = null
    }
    queue.running = false
    if (this.queues.get(deviceID) === queue) this.queues.delete(deviceID)
  }
}
