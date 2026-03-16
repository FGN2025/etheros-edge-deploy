import type {
  Terminal, Subscriber, Agent, RevenueMonth, ActivityEvent, ISPSettings,
  InsertTerminal, InsertSubscriber, InsertAgent
} from "@shared/schema";
import { randomUUID } from "crypto";

export interface IStorage {
  getTerminals(): Promise<Terminal[]>;
  getTerminal(id: string): Promise<Terminal | undefined>;
  updateTerminal(id: string, patch: Partial<Terminal>): Promise<Terminal | undefined>;
  getSubscribers(): Promise<Subscriber[]>;
  getSubscriber(id: string): Promise<Subscriber | undefined>;
  updateSubscriber(id: string, patch: Partial<Subscriber>): Promise<Subscriber | undefined>;
  createSubscriber(sub: InsertSubscriber): Promise<Subscriber>;
  getAgents(): Promise<Agent[]>;
  getAgent(id: string): Promise<Agent | undefined>;
  createAgent(agent: InsertAgent): Promise<Agent>;
  toggleAgent(id: string, enabled: boolean): Promise<Agent | undefined>;
  getRevenue(): Promise<RevenueMonth[]>;
  recordRevenueSnapshot(snap: RevenueMonth): Promise<RevenueMonth>;
  getActivity(): Promise<ActivityEvent[]>;
  getSettings(): Promise<ISPSettings>;
  updateSettings(settings: Partial<ISPSettings>): Promise<ISPSettings>;
}

function generateTerminals(): Terminal[] {
  const hostnames = [
    'edge-core-01', 'edge-core-02', 'edge-core-03', 'edge-node-04', 'edge-node-05',
    'edge-node-06', 'edge-gpu-07', 'edge-gpu-08', 'edge-gpu-09', 'edge-node-10',
    'edge-node-11', 'edge-core-12', 'edge-node-13', 'edge-gpu-14', 'edge-node-15',
    'edge-node-16', 'edge-core-17', 'edge-node-18', 'edge-node-19', 'edge-gpu-20',
    'edge-node-21', 'edge-node-22', 'edge-core-23', 'edge-node-24', 'edge-node-25',
    'edge-gpu-26', 'edge-node-27', 'edge-node-28', 'edge-core-29', 'edge-node-30',
    'edge-node-31', 'edge-gpu-32', 'edge-node-33', 'edge-node-34', 'edge-core-35',
    'edge-node-36', 'edge-node-37', 'edge-gpu-38', 'edge-node-39', 'edge-node-40',
    'edge-core-41', 'edge-node-42', 'edge-node-43', 'edge-gpu-44', 'edge-node-45',
    'edge-node-46', 'edge-core-47'
  ];
  const models = ['llama3.2:3b', 'llama3.1:8b', 'mistral:7b', 'phi3:14b', 'gemma2:9b'];
  const osVersions = ['EtherOS 1.2.4', 'EtherOS 1.2.3', 'EtherOS 1.3.0-beta'];

  return hostnames.map((hostname, i) => {
    const isOnline = i < 38;
    const isProvisioning = i >= 45;
    const status: Terminal['status'] = isProvisioning ? 'provisioning' : isOnline ? 'online' : 'offline';
    const tier: 1 | 2 = hostname.includes('core') || hostname.includes('gpu') ? 1 : 2;

    return {
      id: randomUUID(),
      hostname,
      ip: `10.0.${Math.floor(i / 255)}.${(i % 255) + 1}`,
      tier,
      status,
      modelVersion: models[i % models.length],
      lastSeen: status === 'online' ? new Date().toISOString() : new Date(Date.now() - (i * 3600000)).toISOString(),
      osVersion: osVersions[i % osVersions.length],
      cpuPercent: status === 'online' ? Math.floor(Math.random() * 60) + 15 : 0,
      ramPercent: status === 'online' ? Math.floor(Math.random() * 50) + 30 : 0,
      diskPercent: Math.floor(Math.random() * 40) + 25,
      modelLoaded: models[i % models.length],
      lastInferenceTime: status === 'online' ? Math.floor(Math.random() * 800) + 50 : 0,
      uptime: status === 'online' ? `${Math.floor(Math.random() * 30) + 1}d ${Math.floor(Math.random() * 24)}h` : '0d 0h',
    };
  });
}

function generateSubscribers(): Subscriber[] {
  const firstNames = ['James', 'Maria', 'Chen', 'Sarah', 'David', 'Emily', 'Michael', 'Lisa', 'Robert', 'Ana', 'John', 'Kate', 'Tom', 'Priya', 'Alex', 'Rachel', 'Sam', 'Diana', 'Paul', 'Mia'];
  const lastNames = ['Smith', 'Garcia', 'Wang', 'Johnson', 'Brown', 'Martinez', 'Anderson', 'Taylor', 'Thomas', 'Hernandez', 'Moore', 'Wilson', 'Clark', 'Patel', 'Lewis', 'Hall', 'Young', 'Allen', 'King', 'Wright'];
  const agentNames = ['Code Assistant', 'Writing Helper', 'Data Analyst', 'Research Bot', 'Email Drafter', 'Meeting Summarizer', 'Creative Writer', 'SQL Expert'];

  const subs: Subscriber[] = [];
  for (let i = 0; i < 312; i++) {
    const first = firstNames[i % firstNames.length];
    const last = lastNames[Math.floor(i / firstNames.length) % lastNames.length];
    let plan: Subscriber['plan'];
    if (i < 280) plan = 'personal';
    else if (i < 308) plan = 'professional';
    else plan = 'charter';

    const planPrice = plan === 'personal' ? 14.99 : plan === 'professional' ? 39.99 : 99.99;
    const numAgents = plan === 'charter' ? Math.floor(Math.random() * 5) + 3 : plan === 'professional' ? Math.floor(Math.random() * 3) + 1 : Math.floor(Math.random() * 2);
    const agentAddons = numAgents * 4.99;
    const isSuspended = i > 295 && i < 300;

    subs.push({
      id: randomUUID(),
      name: `${first} ${last}${i >= 20 ? ` ${String(Math.floor(i / 20))}` : ''}`,
      email: `${first.toLowerCase()}.${last.toLowerCase()}${i >= 20 ? Math.floor(i / 20) : ''}@example.com`,
      plan,
      status: isSuspended ? 'suspended' : 'active',
      agentsActive: numAgents,
      monthlySpend: Math.round((planPrice + agentAddons) * 100) / 100,
      joinedAt: new Date(Date.now() - Math.floor(Math.random() * 365 * 24 * 3600000)).toISOString(),
      agents: Array.from({ length: numAgents }, (_, j) => agentNames[(i + j) % agentNames.length]),
      billingHistory: Array.from({ length: 3 }, (_, j) => ({
        date: new Date(Date.now() - j * 30 * 24 * 3600000).toISOString().slice(0, 10),
        amount: Math.round((planPrice + agentAddons) * 100) / 100,
        status: 'paid'
      })),
    });
  }
  return subs;
}

function generateAgents(): Agent[] {
  return [
    { id: randomUUID(), name: 'Code Assistant', slug: 'code-assistant', description: 'AI-powered coding companion for debugging, refactoring, and code generation across multiple languages.', category: 'Development', creatorRole: 'etheros', status: 'live', pricingType: 'free', priceMonthly: 0, activationCount: 189, isEnabled: true, modelId: 'llama3.1:8b', systemPrompt: 'You are an expert software developer...' },
    { id: randomUUID(), name: 'Writing Helper', slug: 'writing-helper', description: 'Professional writing assistant for emails, documents, and creative content.', category: 'Productivity', creatorRole: 'etheros', status: 'live', pricingType: 'free', priceMonthly: 0, activationCount: 156, isEnabled: true, modelId: 'llama3.2:3b', systemPrompt: 'You are a professional writer...' },
    { id: randomUUID(), name: 'Data Analyst', slug: 'data-analyst', description: 'SQL query builder and data visualization assistant for business intelligence.', category: 'Analytics', creatorRole: 'etheros', status: 'live', pricingType: 'addon', priceMonthly: 4.99, activationCount: 87, isEnabled: true, modelId: 'mistral:7b', systemPrompt: 'You are a data analyst expert...' },
    { id: randomUUID(), name: 'Research Bot', slug: 'research-bot', description: 'Deep research assistant for academic and business research tasks.', category: 'Research', creatorRole: 'etheros', status: 'live', pricingType: 'addon', priceMonthly: 4.99, activationCount: 64, isEnabled: true, modelId: 'phi3:14b', systemPrompt: 'You are a research specialist...' },
    { id: randomUUID(), name: 'Email Drafter', slug: 'email-drafter', description: 'Compose professional emails with tone and context awareness.', category: 'Productivity', creatorRole: 'isp', status: 'live', pricingType: 'addon', priceMonthly: 2.99, activationCount: 45, isEnabled: true, modelId: 'llama3.2:3b', systemPrompt: 'You are an email drafting assistant...' },
    { id: randomUUID(), name: 'Meeting Summarizer', slug: 'meeting-summarizer', description: 'Summarize meeting transcripts into action items and key decisions.', category: 'Productivity', creatorRole: 'isp', status: 'live', pricingType: 'addon', priceMonthly: 3.99, activationCount: 32, isEnabled: true, modelId: 'llama3.1:8b', systemPrompt: 'You summarize meetings...' },
    { id: randomUUID(), name: 'Creative Writer', slug: 'creative-writer', description: 'Fiction, poetry, and creative content generation with style control.', category: 'Creative', creatorRole: 'third_party', status: 'review', pricingType: 'addon', priceMonthly: 4.99, activationCount: 12, isEnabled: false, modelId: 'gemma2:9b', systemPrompt: 'You are a creative writing specialist...' },
    { id: randomUUID(), name: 'SQL Expert', slug: 'sql-expert', description: 'Advanced SQL query generation and database optimization assistant.', category: 'Development', creatorRole: 'third_party', status: 'live', pricingType: 'addon', priceMonthly: 5.99, activationCount: 28, isEnabled: true, modelId: 'mistral:7b', systemPrompt: 'You are an SQL database expert...' },
  ];
}

function generateRevenue(): RevenueMonth[] {
  const months = ['Apr 2025', 'May 2025', 'Jun 2025', 'Jul 2025', 'Aug 2025', 'Sep 2025', 'Oct 2025', 'Nov 2025', 'Dec 2025', 'Jan 2026', 'Feb 2026', 'Mar 2026'];
  const baseSubs = 180;
  return months.map((month, i) => {
    const subs = baseSubs + i * 12 + Math.floor(Math.random() * 8);
    const baseRevenue = subs * 18.5 + Math.floor(Math.random() * 500);
    const agentRev = subs * 2.8 + Math.floor(Math.random() * 200);
    const total = baseRevenue + agentRev;
    return {
      month,
      totalRevenue: Math.round(total),
      ispShare: Math.round(total * 0.3),
      agentRevenue: Math.round(agentRev),
      subscriberCount: subs,
    };
  });
}

function generateActivity(): ActivityEvent[] {
  return [
    { id: randomUUID(), type: 'terminal', message: 'edge-gpu-38 came online', timestamp: new Date(Date.now() - 120000).toISOString() },
    { id: randomUUID(), type: 'subscriber', message: 'Sarah Johnson activated Data Analyst agent', timestamp: new Date(Date.now() - 900000).toISOString() },
    { id: randomUUID(), type: 'terminal', message: 'edge-node-40 went offline (scheduled maintenance)', timestamp: new Date(Date.now() - 1800000).toISOString() },
    { id: randomUUID(), type: 'agent', message: 'Creative Writer submitted for review by third-party dev', timestamp: new Date(Date.now() - 3600000).toISOString() },
    { id: randomUUID(), type: 'subscriber', message: 'Chen Wang upgraded from Personal to Professional plan', timestamp: new Date(Date.now() - 7200000).toISOString() },
  ];
}

export class MemStorage implements IStorage {
  private terminals: Terminal[];
  private subscribers: Subscriber[];
  private agents: Agent[];
  private revenue: RevenueMonth[];
  private activity: ActivityEvent[];
  private settings: ISPSettings;

  constructor() {
    this.terminals = generateTerminals();
    this.subscribers = generateSubscribers();
    this.agents = generateAgents();
    this.revenue = generateRevenue();
    this.activity = generateActivity();
    this.settings = {
      ispName: 'Valley Fiber',
      domain: 'edge.valleyfiber.com',
      logoUrl: 'https://valleyfiber.com/logo.png',
      accentColor: '#00C2CB',
      billingApiEndpoint: 'https://api.valleyfiber.com/billing',
      stripeKey: 'sk_live_****************************xK4m',
      bankDetails: 'Valley Fiber Corp — Routing: ****6789',
      edgeApiKey: 'etheros_****************************aB3c',
      openWebuiToken: 'owui_****************************dE5f',
      alertEmail: 'noc@valleyfiber.com',
      webhookUrl: 'https://hooks.valleyfiber.com/etheros-events',
    };
  }

  async getTerminals() { return this.terminals; }
  async getTerminal(id: string) { return this.terminals.find(t => t.id === id); }
  async updateTerminal(id: string, patch: Partial<Terminal>): Promise<Terminal | undefined> {
    const t = this.terminals.find(t => t.id === id);
    if (!t) return undefined;
    Object.assign(t, patch);
    return t;
  }
  async getSubscribers() { return this.subscribers; }
  async getSubscriber(id: string) { return this.subscribers.find(s => s.id === id); }
  async updateSubscriber(id: string, patch: Partial<Subscriber>): Promise<Subscriber | undefined> {
    const s = this.subscribers.find(s => s.id === id);
    if (!s) return undefined;
    Object.assign(s, patch);
    return s;
  }

  async createSubscriber(data: InsertSubscriber): Promise<Subscriber> {
    const sub: Subscriber = {
      id: randomUUID(),
      ...data,
      status: 'active',
      agentsActive: 0,
      monthlySpend: data.plan === 'personal' ? 14.99 : data.plan === 'professional' ? 39.99 : 99.99,
      joinedAt: new Date().toISOString(),
      agents: [],
      billingHistory: [],
    };
    this.subscribers.push(sub);
    return sub;
  }

  async getAgents() { return this.agents; }
  async getAgent(id: string) { return this.agents.find(a => a.id === id); }

  async createAgent(data: InsertAgent): Promise<Agent> {
    const agent: Agent = {
      id: randomUUID(),
      ...data,
      slug: data.name.toLowerCase().replace(/\s+/g, '-'),
      creatorRole: 'isp',
      status: 'draft',
      activationCount: 0,
      isEnabled: false,
      modelId: data.modelId,
      systemPrompt: data.systemPrompt,
    };
    this.agents.push(agent);
    return agent;
  }

  async toggleAgent(id: string, enabled: boolean): Promise<Agent | undefined> {
    const agent = this.agents.find(a => a.id === id);
    if (agent) agent.isEnabled = enabled;
    return agent;
  }

  async getRevenue() { return this.revenue; }
  async recordRevenueSnapshot(snap: RevenueMonth): Promise<RevenueMonth> {
    // Replace existing entry for same month, or append
    const idx = this.revenue.findIndex(r => r.month === snap.month);
    if (idx >= 0) { this.revenue[idx] = snap; } else { this.revenue.push(snap); }
    return snap;
  }
  async getActivity() { return this.activity; }
  async getSettings() { return this.settings; }

  async updateSettings(data: Partial<ISPSettings>): Promise<ISPSettings> {
    this.settings = { ...this.settings, ...data };
    return this.settings;
  }
}

export const storage = new MemStorage();
