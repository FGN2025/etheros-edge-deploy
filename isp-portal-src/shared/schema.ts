import { z } from "zod";

// Terminal
export interface Terminal {
  id: string;
  hostname: string;
  ip: string;
  tier: 1 | 2;
  status: 'online' | 'offline' | 'provisioning' | 'decommissioned';
  modelVersion: string;
  lastSeen: string;
  osVersion: string;
  cpuPercent: number;
  ramPercent: number;
  diskPercent: number;
  modelLoaded: string;
  lastInferenceTime: number; // ms
  uptime: string;
}

// Subscriber
export interface Subscriber {
  id: string;
  name: string;
  email: string;
  plan: 'personal' | 'professional' | 'charter';
  status: 'active' | 'suspended';
  agentsActive: number;
  monthlySpend: number;
  joinedAt: string;
  agents: string[];
  billingHistory: { date: string; amount: number; status: string }[];
}

// Agent
export interface Agent {
  id: string;
  name: string;
  slug: string;
  description: string;
  category: string;
  creatorRole: 'etheros' | 'isp' | 'third_party';
  status: 'live' | 'review' | 'draft';
  pricingType: 'free' | 'addon';
  priceMonthly: number;
  activationCount: number;
  isEnabled: boolean;
  modelId: string;
  systemPrompt: string;
}

// Revenue monthly
export interface RevenueMonth {
  month: string;
  totalRevenue: number;
  ispShare: number;
  agentRevenue: number;
  subscriberCount: number;
}

// Activity event
export interface ActivityEvent {
  id: string;
  type: string;
  message: string;
  timestamp: string;
}

// Settings
export interface ISPSettings {
  ispName: string;
  domain: string;
  logoUrl: string;
  accentColor: string;
  billingApiEndpoint: string;
  stripeKey: string;
  bankDetails: string;
  edgeApiKey: string;
  openWebuiToken: string;
  alertEmail: string;
  webhookUrl: string;
}

// Insert schemas
export const insertTerminalSchema = z.object({
  hostname: z.string().min(1),
  ip: z.string().min(1),
  tier: z.number().min(1).max(2),
  status: z.enum(['online', 'offline', 'provisioning', 'decommissioned']),
});

export const insertSubscriberSchema = z.object({
  name: z.string().min(1),
  email: z.string().email(),
  plan: z.enum(['personal', 'professional', 'charter']),
});

export const insertAgentSchema = z.object({
  name: z.string().min(1),
  description: z.string().min(1),
  category: z.string().min(1),
  modelId: z.string().min(1),
  systemPrompt: z.string().min(1),
  pricingType: z.enum(['free', 'addon']),
  priceMonthly: z.number().min(0),
});

export type InsertTerminal = z.infer<typeof insertTerminalSchema>;
export type InsertSubscriber = z.infer<typeof insertSubscriberSchema>;
export type InsertAgent = z.infer<typeof insertAgentSchema>;

// ── Stripe / Billing ─────────────────────────────────────────────────────────

export type StripePlanId = 'starter' | 'growth' | 'enterprise';

export interface StripePlan {
  id: StripePlanId;
  name: string;
  description: string;
  priceMonthly: number;       // USD cents → display as dollars
  terminalLimit: number;
  subscriberLimit: number;
  features: string[];
  stripePriceId: string;      // live Stripe Price ID
  stripePriceIdTest: string;  // test Stripe Price ID
}

export const STRIPE_PLANS: StripePlan[] = [
  {
    id: 'starter',
    name: 'Starter',
    description: 'Perfect for rural ISPs getting started with AI-powered terminals.',
    priceMonthly: 29900,   // $299/mo
    terminalLimit: 25,
    subscriberLimit: 200,
    features: [
      'Up to 25 EtherOS terminals',
      'Up to 200 active subscribers',
      'All free marketplace agents',
      'Basic analytics dashboard',
      'Email support',
    ],
    stripePriceId: 'price_starter_live',
    stripePriceIdTest: 'price_starter_test',
  },
  {
    id: 'growth',
    name: 'Growth',
    description: 'For expanding ISPs with growing subscriber bases and premium agents.',
    priceMonthly: 79900,   // $799/mo
    terminalLimit: 100,
    subscriberLimit: 1000,
    features: [
      'Up to 100 EtherOS terminals',
      'Up to 1,000 active subscribers',
      'All marketplace agents including premium',
      'Full revenue analytics + export',
      'Priority support + SLA',
      'White-label branding',
    ],
    stripePriceId: 'price_growth_live',
    stripePriceIdTest: 'price_growth_test',
  },
  {
    id: 'enterprise',
    name: 'Enterprise',
    description: 'Unlimited scale for large regional ISPs and multi-state operators.',
    priceMonthly: 199900,  // $1,999/mo
    terminalLimit: 9999,
    subscriberLimit: 9999,
    features: [
      'Unlimited EtherOS terminals',
      'Unlimited active subscribers',
      'All agents + first access to new releases',
      'Custom agent development',
      'Dedicated account manager',
      'Custom integrations + API access',
    ],
    stripePriceId: 'price_enterprise_live',
    stripePriceIdTest: 'price_enterprise_test',
  },
];

export interface BillingStatus {
  customerId: string | null;
  subscriptionId: string | null;
  planId: StripePlanId | null;
  status: 'active' | 'trialing' | 'past_due' | 'canceled' | 'none';
  currentPeriodEnd: string | null;
  cancelAtPeriodEnd: boolean;
  trialEnd: string | null;
  paymentMethodLast4: string | null;
  paymentMethodBrand: string | null;
  invoices: BillingInvoice[];
}

export interface BillingInvoice {
  id: string;
  date: string;
  amount: number;       // cents
  status: 'paid' | 'open' | 'uncollectible' | 'void';
  pdfUrl: string | null;
  hostedUrl: string | null;
}

export interface CreateCheckoutSessionRequest {
  planId: StripePlanId;
  successUrl: string;
  cancelUrl: string;
}

export interface CreatePortalSessionRequest {
  returnUrl: string;
}
