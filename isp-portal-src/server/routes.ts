import type { Express, Request, Response } from "express";
import { createServer, type Server } from "http";
import { storage } from "./storage";
import { insertSubscriberSchema, insertAgentSchema } from "@shared/schema";
import { registerStripeRoutes } from "./stripe";

// Ollama runs on the same VPS — hit it directly to avoid external round-trip
const OLLAMA_BASE = process.env.OLLAMA_BASE_URL ?? "http://127.0.0.1:11434";

async function fetchEdgeStatus() {
  try {
    const modelsRes = await fetch(`${OLLAMA_BASE}/api/tags`, { signal: AbortSignal.timeout(5000) });

    let models: any[] = [];
    if (modelsRes.ok) {
      const body = await modelsRes.json();
      // Ollama /api/tags returns { models: [{name, ...}] }
      models = (body?.models ?? []).map((m: any) => m.name ?? m.id ?? "unknown");
    }

    return {
      health: modelsRes.ok ? { status: "ok" } : null,
      models,
      ollamaOnline: modelsRes.ok && models.length > 0,
    };
  } catch (err: any) {
    return {
      health: null,
      models: [],
      ollamaOnline: false,
      error: err?.message ?? "Ollama unreachable",
    };
  }
}

export async function registerRoutes(
  httpServer: Server,
  app: Express
): Promise<Server> {
  // ── Edge Status (live VPS) ──
  app.get("/api/edge-status", async (_req, res) => {
    const status = await fetchEdgeStatus();
    res.json(status);
  });

  // ── Edge Chat proxy (streaming) ──
  app.post("/api/edge-chat", async (req: Request, res: Response) => {
    const { model, messages } = req.body;
    if (!model || !Array.isArray(messages)) {
      return res.status(400).json({ error: "model and messages[] are required" });
    }

    try {
      const upstream = await fetch(`${EDGE_API_BASE}/chat/completions`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ model, messages, stream: true }),
        signal: AbortSignal.timeout(120000),
      });

      if (!upstream.ok) {
        const errText = await upstream.text();
        return res.status(upstream.status).json({ error: errText });
      }

      res.setHeader("Content-Type", upstream.headers.get("content-type") || "text/event-stream");
      res.setHeader("Cache-Control", "no-cache");
      res.setHeader("Connection", "keep-alive");

      if (upstream.body) {
        const reader = (upstream.body as any).getReader();
        const pump = async () => {
          while (true) {
            const { done, value } = await reader.read();
            if (done) { res.end(); break; }
            res.write(value);
          }
        };
        pump().catch(() => res.end());
      } else {
        const text = await upstream.text();
        res.send(text);
      }
    } catch (err: any) {
      if (!res.headersSent) {
        res.status(502).json({ error: err?.message ?? "Edge unreachable" });
      }
    }
  });

  // Terminals
  app.get("/api/terminals", async (_req, res) => {
    const terminals = await storage.getTerminals();
    res.json(terminals);
  });

  app.get("/api/terminals/:id", async (req, res) => {
    const terminal = await storage.getTerminal(req.params.id);
    if (!terminal) return res.status(404).json({ error: "Not found" });
    res.json(terminal);
  });

  app.patch("/api/terminals/:id", async (req, res) => {
    const allowed: Array<keyof import("@shared/schema").Terminal> = ['status', 'tier', 'modelLoaded', 'modelVersion', 'osVersion'];
    const patch: Record<string, any> = {};
    for (const key of allowed) { if (key in req.body) patch[key] = req.body[key]; }
    const terminal = await storage.updateTerminal(req.params.id, patch);
    if (!terminal) return res.status(404).json({ error: "Not found" });
    res.json(terminal);
  });

  // Subscribers
  app.get("/api/subscribers", async (_req, res) => {
    const subscribers = await storage.getSubscribers();
    res.json(subscribers);
  });

  app.get("/api/subscribers/:id", async (req, res) => {
    const subscriber = await storage.getSubscriber(req.params.id);
    if (!subscriber) return res.status(404).json({ error: "Not found" });
    res.json(subscriber);
  });

  app.patch("/api/subscribers/:id", async (req, res) => {
    const allowed: Array<keyof import("@shared/schema").Subscriber> = ['status', 'plan', 'agents', 'agentsActive'];
    const patch: Record<string, any> = {};
    for (const key of allowed) { if (key in req.body) patch[key] = req.body[key]; }
    const subscriber = await storage.updateSubscriber(req.params.id, patch);
    if (!subscriber) return res.status(404).json({ error: "Not found" });
    res.json(subscriber);
  });

  app.post("/api/subscribers", async (req, res) => {
    const parsed = insertSubscriberSchema.safeParse(req.body);
    if (!parsed.success) return res.status(400).json({ error: parsed.error.message });
    const subscriber = await storage.createSubscriber(parsed.data);
    res.status(201).json(subscriber);
  });

  // Agents
  app.get("/api/agents", async (_req, res) => {
    const agents = await storage.getAgents();
    res.json(agents);
  });

  app.post("/api/agents", async (req, res) => {
    const parsed = insertAgentSchema.safeParse(req.body);
    if (!parsed.success) return res.status(400).json({ error: parsed.error.message });
    const agent = await storage.createAgent(parsed.data);
    res.status(201).json(agent);
  });

  app.patch("/api/agents/:id/toggle", async (req, res) => {
    const { enabled } = req.body;
    const agent = await storage.toggleAgent(req.params.id, enabled);
    if (!agent) return res.status(404).json({ error: "Not found" });
    res.json(agent);
  });

  // Revenue
  app.get("/api/revenue", async (_req, res) => {
    const revenue = await storage.getRevenue();
    res.json(revenue);
  });

  // Activity
  app.get("/api/activity", async (_req, res) => {
    const activity = await storage.getActivity();
    res.json(activity);
  });

  // Settings
  app.get("/api/settings", async (_req, res) => {
    const settings = await storage.getSettings();
    res.json(settings);
  });

  app.patch("/api/settings", async (req, res) => {
    const settings = await storage.updateSettings(req.body);
    res.json(settings);
  });

  // Dashboard summary
  app.get("/api/dashboard", async (_req, res) => {
    const terminals = await storage.getTerminals();
    const subscribers = await storage.getSubscribers();
    const revenue = await storage.getRevenue();
    const activity = await storage.getActivity();

    const activeTerminals = terminals.filter(t => t.status !== 'decommissioned');
    const online = activeTerminals.filter(t => t.status === 'online').length;
    const offline = activeTerminals.filter(t => t.status === 'offline').length;
    const provisioning = activeTerminals.filter(t => t.status === 'provisioning').length;
    const activeSubs = subscribers.filter(s => s.status === 'active').length;
    const latestRev = revenue[revenue.length - 1];
    const prevRev = revenue[revenue.length - 2];
    const totalMonthlySpend = subscribers.reduce((sum, s) => sum + s.monthlySpend, 0);
    const arpu = activeSubs > 0 ? totalMonthlySpend / activeSubs : 0;

    // Fetch live edge status (non-blocking — don't fail the dashboard if VPS is down)
    const edgeStatus = await fetchEdgeStatus();
    const liveModels = edgeStatus.models.map((m: any) => m.name ?? m.id ?? "unknown");

    res.json({
      totalTerminals: activeTerminals.length,
      online,
      offline,
      provisioning,
      activeSubscribers: activeSubs,
      monthlyRevenue: latestRev?.ispShare || 0,
      prevMonthlyRevenue: prevRev?.ispShare || 0,
      arpu: Math.round(arpu * 100) / 100,
      revenueByMonth: revenue.slice(-6),
      activity,
      liveModels,
      edgeOnline: edgeStatus.ollamaOnline,
      edgeUrl: "https://edge.etheros.ai",
    });
  });

  // ── Stripe Billing ──
  registerStripeRoutes(app);

  return httpServer;
}
