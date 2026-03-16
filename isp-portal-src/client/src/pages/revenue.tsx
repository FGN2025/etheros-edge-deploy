import { useState } from "react";
import { useQuery, useMutation } from "@tanstack/react-query";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { Download, TrendingUp, Camera, CheckCircle2, Loader2 } from "lucide-react";
import { apiRequest, queryClient } from "@/lib/queryClient";
import { useToast } from "@/hooks/use-toast";
import {
  LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer,
} from "recharts";
import type { RevenueMonth } from "@shared/schema";

const TEAL = "hsl(183, 100%, 40%)";

function exportCSV(revenue: RevenueMonth[]) {
  const header = "Month,Total Revenue,ISP Share (30%),EtherOS Share (70%),Agent Revenue,Subscribers\n";
  const rows = revenue.map(r =>
    `${r.month},${r.totalRevenue},${r.ispShare},${r.totalRevenue - r.ispShare},${r.agentRevenue},${r.subscriberCount}`
  ).join("\n");
  const blob = new Blob([header + rows], { type: 'text/csv' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = 'etheros-revenue-export.csv';
  a.click();
  URL.revokeObjectURL(url);
}

export default function Revenue() {
  const { toast } = useToast();
  const [lastSnap, setLastSnap] = useState<string | null>(null);

  const { data: revenue, isLoading } = useQuery<RevenueMonth[]>({
    queryKey: ["/api/revenue"],
  });

  const snapshotMutation = useMutation({
    mutationFn: async () => {
      const res = await apiRequest("POST", "/api/revenue/snapshot");
      return res.json();
    },
    onSuccess: (snap: RevenueMonth) => {
      queryClient.invalidateQueries({ queryKey: ["/api/revenue"] });
      setLastSnap(snap.month);
      toast({ title: `Snapshot recorded`, description: `${snap.month} — $${snap.totalRevenue.toLocaleString()} total revenue` });
    },
    onError: () => {
      toast({ title: 'Snapshot failed', variant: 'destructive' });
    },
  });

  if (isLoading || !revenue) {
    return (
      <div className="p-6 space-y-6">
        <Skeleton className="h-10 w-48" />
        <Skeleton className="h-72" />
        <Skeleton className="h-64" />
      </div>
    );
  }

  // Compute ARPU per month
  const arpuData = revenue.map(r => ({
    month: r.month.replace('2025', '25').replace('2026', '26'),
    arpu: r.subscriberCount > 0 ? Math.round(r.totalRevenue / r.subscriberCount * 100) / 100 : 0,
  }));

  // Plan breakdown (latest month)
  const latest = revenue[revenue.length - 1];
  // Estimated breakdown based on typical subscriber distribution
  const planBreakdown = [
    { plan: 'Personal', subscribers: 280, pricePerUser: 14.99, monthlyRev: 280 * 14.99 },
    { plan: 'Professional', subscribers: 28, pricePerUser: 39.99, monthlyRev: 28 * 39.99 },
    { plan: 'Charter', subscribers: 4, pricePerUser: 99.99, monthlyRev: 4 * 99.99 },
  ];
  const totalPlanRev = planBreakdown.reduce((s, p) => s + p.monthlyRev, 0);

  // Agent revenue
  const agentAttachRate = latest ? Math.round((latest.agentRevenue / latest.totalRevenue) * 100) : 0;

  return (
    <div className="p-6 space-y-6" data-testid="revenue-page">
      <div className="flex items-center justify-between gap-3 flex-wrap">
        <div>
          <h1 className="text-lg font-semibold" style={{ fontFamily: 'var(--font-display)' }}>Revenue</h1>
          {lastSnap && (
            <p className="text-xs text-emerald-400 flex items-center gap-1 mt-0.5">
              <CheckCircle2 className="h-3 w-3" /> Snapshot recorded for {lastSnap}
            </p>
          )}
        </div>
        <div className="flex items-center gap-2">
          <Button
            size="sm"
            variant="outline"
            className="gap-1.5 border-primary/40 text-primary hover:bg-primary/10"
            disabled={snapshotMutation.isPending}
            onClick={() => snapshotMutation.mutate()}
            data-testid="button-snapshot"
          >
            {snapshotMutation.isPending
              ? <Loader2 className="h-3.5 w-3.5 animate-spin" />
              : <Camera className="h-3.5 w-3.5" />}
            Record Snapshot
          </Button>
          <Button size="sm" variant="outline" className="gap-1.5" onClick={() => exportCSV(revenue)} data-testid="button-export-csv">
            <Download className="h-3.5 w-3.5" /> Export CSV
          </Button>
        </div>
      </div>

      {/* ARPU Chart */}
      <Card className="bg-card border-card-border">
        <CardHeader className="pb-2">
          <CardTitle className="text-sm font-semibold flex items-center gap-2" style={{ fontFamily: 'var(--font-display)' }}>
            <TrendingUp className="h-4 w-4 text-primary" /> Monthly ARPU — Last 12 Months
          </CardTitle>
        </CardHeader>
        <CardContent>
          <ResponsiveContainer width="100%" height={260}>
            <LineChart data={arpuData}>
              <CartesianGrid strokeDasharray="3 3" stroke="hsl(212, 30%, 18%)" />
              <XAxis dataKey="month" tick={{ fontSize: 11, fill: 'hsl(215, 16%, 55%)' }} axisLine={false} tickLine={false} />
              <YAxis tick={{ fontSize: 11, fill: 'hsl(215, 16%, 55%)' }} axisLine={false} tickLine={false} tickFormatter={v => `$${v}`} domain={['auto', 'auto']} />
              <Tooltip
                contentStyle={{
                  backgroundColor: 'hsl(212, 40%, 12%)',
                  border: '1px solid hsl(212, 30%, 22%)',
                  borderRadius: '6px',
                  fontSize: '12px',
                  color: 'hsl(210, 40%, 96%)',
                }}
                formatter={(v: number) => [`$${v.toFixed(2)}`, 'ARPU']}
              />
              <Line type="monotone" dataKey="arpu" stroke={TEAL} strokeWidth={2} dot={{ r: 3, fill: TEAL }} activeDot={{ r: 5 }} />
            </LineChart>
          </ResponsiveContainer>
        </CardContent>
      </Card>

      {/* Revenue Breakdown Table */}
      <Card className="bg-card border-card-border">
        <CardHeader className="pb-2">
          <CardTitle className="text-sm font-semibold" style={{ fontFamily: 'var(--font-display)' }}>Revenue Breakdown by Plan</CardTitle>
        </CardHeader>
        <CardContent>
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-border bg-muted/30">
                  <th className="text-left px-4 py-2.5 text-xs font-semibold text-muted-foreground uppercase tracking-wider">Plan Tier</th>
                  <th className="text-right px-4 py-2.5 text-xs font-semibold text-muted-foreground uppercase tracking-wider">Subscribers</th>
                  <th className="text-right px-4 py-2.5 text-xs font-semibold text-muted-foreground uppercase tracking-wider">Monthly Revenue</th>
                  <th className="text-right px-4 py-2.5 text-xs font-semibold text-muted-foreground uppercase tracking-wider">ISP Share (30%)</th>
                  <th className="text-right px-4 py-2.5 text-xs font-semibold text-muted-foreground uppercase tracking-wider">EtherOS Share</th>
                </tr>
              </thead>
              <tbody>
                {planBreakdown.map((p) => (
                  <tr key={p.plan} className="border-b border-border/50">
                    <td className="px-4 py-2.5 text-sm font-medium text-foreground">{p.plan}</td>
                    <td className="px-4 py-2.5 text-sm tabular-nums text-right text-foreground">{p.subscribers}</td>
                    <td className="px-4 py-2.5 text-sm tabular-nums text-right text-foreground">${p.monthlyRev.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}</td>
                    <td className="px-4 py-2.5 text-sm tabular-nums text-right text-primary font-medium">${(p.monthlyRev * 0.3).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}</td>
                    <td className="px-4 py-2.5 text-sm tabular-nums text-right text-muted-foreground">${(p.monthlyRev * 0.7).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}</td>
                  </tr>
                ))}
                <tr className="bg-muted/20 font-semibold">
                  <td className="px-4 py-2.5 text-sm text-foreground">Total</td>
                  <td className="px-4 py-2.5 text-sm tabular-nums text-right text-foreground">{planBreakdown.reduce((s, p) => s + p.subscribers, 0)}</td>
                  <td className="px-4 py-2.5 text-sm tabular-nums text-right text-foreground">${totalPlanRev.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}</td>
                  <td className="px-4 py-2.5 text-sm tabular-nums text-right text-primary">${(totalPlanRev * 0.3).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}</td>
                  <td className="px-4 py-2.5 text-sm tabular-nums text-right text-muted-foreground">${(totalPlanRev * 0.7).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </CardContent>
      </Card>

      {/* Agent Marketplace Revenue */}
      <Card className="bg-card border-card-border">
        <CardHeader className="pb-2">
          <CardTitle className="text-sm font-semibold" style={{ fontFamily: 'var(--font-display)' }}>Agent Marketplace Add-on Revenue</CardTitle>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
            <div className="bg-muted/20 rounded-lg p-4">
              <p className="text-xs text-muted-foreground mb-1">Attach Rate</p>
              <p className="text-xl font-bold text-foreground tabular-nums" style={{ fontFamily: 'var(--font-display)' }}>{agentAttachRate}%</p>
            </div>
            <div className="bg-muted/20 rounded-lg p-4">
              <p className="text-xs text-muted-foreground mb-1">Agent Revenue (This Month)</p>
              <p className="text-xl font-bold text-foreground tabular-nums" style={{ fontFamily: 'var(--font-display)' }}>${latest?.agentRevenue.toLocaleString()}</p>
            </div>
            <div className="bg-muted/20 rounded-lg p-4">
              <p className="text-xs text-muted-foreground mb-1">ISP Agent Share (30%)</p>
              <p className="text-xl font-bold text-primary tabular-nums" style={{ fontFamily: 'var(--font-display)' }}>${latest ? Math.round(latest.agentRevenue * 0.3).toLocaleString() : 0}</p>
            </div>
          </div>

          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-border bg-muted/30">
                  <th className="text-left px-4 py-2.5 text-xs font-semibold text-muted-foreground uppercase tracking-wider">Month</th>
                  <th className="text-right px-4 py-2.5 text-xs font-semibold text-muted-foreground uppercase tracking-wider">Total Revenue</th>
                  <th className="text-right px-4 py-2.5 text-xs font-semibold text-muted-foreground uppercase tracking-wider">ISP Share</th>
                  <th className="text-right px-4 py-2.5 text-xs font-semibold text-muted-foreground uppercase tracking-wider">Agent Revenue</th>
                  <th className="text-right px-4 py-2.5 text-xs font-semibold text-muted-foreground uppercase tracking-wider">Subscribers</th>
                </tr>
              </thead>
              <tbody>
                {revenue.slice().reverse().map(r => (
                  <tr key={r.month} className="border-b border-border/50">
                    <td className="px-4 py-2.5 text-sm text-foreground">{r.month}</td>
                    <td className="px-4 py-2.5 text-sm tabular-nums text-right text-foreground">${r.totalRevenue.toLocaleString()}</td>
                    <td className="px-4 py-2.5 text-sm tabular-nums text-right text-primary font-medium">${r.ispShare.toLocaleString()}</td>
                    <td className="px-4 py-2.5 text-sm tabular-nums text-right text-muted-foreground">${r.agentRevenue.toLocaleString()}</td>
                    <td className="px-4 py-2.5 text-sm tabular-nums text-right text-muted-foreground">{r.subscriberCount}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </CardContent>
      </Card>
    </div>
  );
}
