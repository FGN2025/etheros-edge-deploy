import { useState } from "react";
import { useQuery, useMutation } from "@tanstack/react-query";
import { Card } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Skeleton } from "@/components/ui/skeleton";
import { Sheet, SheetContent, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Search, UserPlus, Package, CreditCard, PauseCircle, PlayCircle, Loader2 } from "lucide-react";
import { apiRequest, queryClient } from "@/lib/queryClient";
import { useToast } from "@/hooks/use-toast";
import type { Subscriber } from "@shared/schema";

type Filter = 'all' | 'active' | 'suspended' | 'personal' | 'professional' | 'charter';

function PlanBadge({ plan }: { plan: string }) {
  const styles: Record<string, string> = {
    personal: 'bg-slate-500/20 text-slate-400 border border-slate-500/30',
    professional: 'bg-cyan-500/20 text-cyan-300 border border-cyan-500/30',
    charter: 'bg-amber-500/20 text-amber-300 border border-amber-500/30',
  };
  return <span className={`${styles[plan] || 'bg-slate-500/20 text-slate-400 border border-slate-500/30'} rounded-full px-2 py-0.5 text-[10px] font-semibold capitalize`}>{plan}</span>;
}

function StatusBadge({ status }: { status: string }) {
  if (status === 'active') return <span className="bg-emerald-500/20 text-emerald-400 border border-emerald-500/30 rounded-full px-2 py-0.5 text-[10px] font-semibold">Active</span>;
  return <span className="bg-red-500/20 text-red-400 border border-red-500/30 rounded-full px-2 py-0.5 text-[10px] font-semibold">Suspended</span>;
}

function SubscriberDrawer({
  subscriber,
  open,
  onClose,
  onToggleStatus,
  isToggling,
}: {
  subscriber: Subscriber | null;
  open: boolean;
  onClose: () => void;
  onToggleStatus: (id: string, newStatus: 'active' | 'suspended') => void;
  isToggling: boolean;
}) {
  if (!subscriber) return null;
  const isSuspended = subscriber.status === 'suspended';
  return (
    <Sheet open={open} onOpenChange={onClose}>
      <SheetContent className="bg-card border-l border-border w-[400px] sm:max-w-[400px] flex flex-col">
        <SheetHeader>
          <SheetTitle className="text-foreground" style={{ fontFamily: 'var(--font-display)' }}>{subscriber.name}</SheetTitle>
          <p className="text-sm text-muted-foreground">{subscriber.email}</p>
          <div className="flex items-center gap-2 pt-1">
            <PlanBadge plan={subscriber.plan} />
            <StatusBadge status={subscriber.status} />
          </div>
        </SheetHeader>
        <div className="mt-6 space-y-5 flex-1 overflow-y-auto">
          <div className="grid grid-cols-2 gap-4">
            <div>
              <p className="text-xs text-muted-foreground mb-1">Monthly Spend</p>
              <p className="text-sm font-semibold text-foreground tabular-nums">${subscriber.monthlySpend}</p>
            </div>
            <div>
              <p className="text-xs text-muted-foreground mb-1">Joined</p>
              <p className="text-sm text-foreground">{new Date(subscriber.joinedAt).toLocaleDateString([], { month: 'short', day: 'numeric', year: 'numeric' })}</p>
            </div>
          </div>

          <div>
            <p className="text-xs font-medium text-muted-foreground mb-2 flex items-center gap-1"><Package className="h-3 w-3" /> Active Agents ({subscriber.agents.length})</p>
            <div className="space-y-1.5">
              {subscriber.agents.length > 0 ? subscriber.agents.map((a, i) => (
                <div key={i} className="text-sm text-foreground bg-muted/30 rounded px-3 py-1.5">{a}</div>
              )) : <p className="text-xs text-muted-foreground">No agents activated</p>}
            </div>
          </div>

          <div>
            <p className="text-xs font-medium text-muted-foreground mb-2 flex items-center gap-1"><CreditCard className="h-3 w-3" /> Billing History</p>
            <div className="space-y-1.5">
              {subscriber.billingHistory.map((b, i) => (
                <div key={i} className="flex items-center justify-between text-xs bg-muted/30 rounded px-3 py-1.5">
                  <span className="text-muted-foreground">{b.date}</span>
                  <span className="tabular-nums text-foreground font-medium">${b.amount}</span>
                  <Badge className="bg-emerald-500/15 text-emerald-400 border-0 text-[10px]">{b.status}</Badge>
                </div>
              ))}
            </div>
          </div>
        </div>

        {/* Action footer */}
        <div className="border-t border-border pt-4 mt-4">
          <Button
            variant="outline"
            size="sm"
            className={`w-full gap-2 ${
              isSuspended
                ? 'border-emerald-500/40 text-emerald-400 hover:bg-emerald-500/10'
                : 'border-amber-500/40 text-amber-400 hover:bg-amber-500/10'
            }`}
            disabled={isToggling}
            onClick={() => onToggleStatus(subscriber.id, isSuspended ? 'active' : 'suspended')}
            data-testid="button-toggle-status"
          >
            {isToggling ? (
              <Loader2 className="h-3.5 w-3.5 animate-spin" />
            ) : isSuspended ? (
              <PlayCircle className="h-3.5 w-3.5" />
            ) : (
              <PauseCircle className="h-3.5 w-3.5" />
            )}
            {isSuspended ? 'Reactivate Subscriber' : 'Suspend Subscriber'}
          </Button>
        </div>
      </SheetContent>
    </Sheet>
  );
}

export default function Subscribers() {
  const [filter, setFilter] = useState<Filter>('all');
  const [search, setSearch] = useState('');
  const [selected, setSelected] = useState<Subscriber | null>(null);
  const [drawerOpen, setDrawerOpen] = useState(false);
  const [dialogOpen, setDialogOpen] = useState(false);
  const [formName, setFormName] = useState('');
  const [formEmail, setFormEmail] = useState('');
  const [formPlan, setFormPlan] = useState('personal');
  const { toast } = useToast();

  const { data: subscribers, isLoading } = useQuery<Subscriber[]>({
    queryKey: ["/api/subscribers"],
  });

  const statusMutation = useMutation({
    mutationFn: async ({ id, status }: { id: string; status: 'active' | 'suspended' }) => {
      const res = await apiRequest("PATCH", `/api/subscribers/${id}`, { status });
      return res.json();
    },
    onSuccess: (updated: Subscriber) => {
      queryClient.invalidateQueries({ queryKey: ["/api/subscribers"] });
      // Update selected so the drawer reflects new status immediately
      setSelected(updated);
      toast({
        title: updated.status === 'suspended' ? 'Subscriber suspended' : 'Subscriber reactivated',
        description: updated.name,
      });
    },
    onError: () => {
      toast({ title: 'Failed to update status', variant: 'destructive' });
    },
  });

  const createMutation = useMutation({
    mutationFn: async (data: { name: string; email: string; plan: string }) => {
      const res = await apiRequest("POST", "/api/subscribers", data);
      return res.json();
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["/api/subscribers"] });
      setDialogOpen(false);
      setFormName(''); setFormEmail(''); setFormPlan('personal');
      toast({ title: "Subscriber added" });
    },
  });

  const filtered = (subscribers || []).filter(s => {
    if (filter === 'active' && s.status !== 'active') return false;
    if (filter === 'suspended' && s.status !== 'suspended') return false;
    if (filter === 'personal' && s.plan !== 'personal') return false;
    if (filter === 'professional' && s.plan !== 'professional') return false;
    if (filter === 'charter' && s.plan !== 'charter') return false;
    if (search) {
      const q = search.toLowerCase();
      return s.name.toLowerCase().includes(q) || s.email.toLowerCase().includes(q);
    }
    return true;
  });

  const filters: { key: Filter; label: string }[] = [
    { key: 'all', label: 'All' },
    { key: 'active', label: 'Active' },
    { key: 'suspended', label: 'Suspended' },
    { key: 'personal', label: 'Personal' },
    { key: 'professional', label: 'Professional' },
    { key: 'charter', label: 'Charter' },
  ];

  return (
    <div className="p-6 space-y-4" data-testid="subscribers-page">
      <div className="flex items-center justify-between">
        <h1 className="text-lg font-semibold" style={{ fontFamily: 'var(--font-display)' }}>Subscribers</h1>
        <Dialog open={dialogOpen} onOpenChange={setDialogOpen}>
          <DialogTrigger asChild>
            <Button size="sm" className="gap-1.5" data-testid="button-add-subscriber">
              <UserPlus className="h-3.5 w-3.5" /> Add Subscriber
            </Button>
          </DialogTrigger>
          <DialogContent className="bg-card border-border">
            <DialogHeader>
              <DialogTitle style={{ fontFamily: 'var(--font-display)' }}>Add Subscriber</DialogTitle>
            </DialogHeader>
            <form onSubmit={(e) => { e.preventDefault(); createMutation.mutate({ name: formName, email: formEmail, plan: formPlan }); }} className="space-y-4 pt-2">
              <div>
                <Label className="text-xs">Name</Label>
                <Input value={formName} onChange={e => setFormName(e.target.value)} placeholder="Full name" className="mt-1 bg-background" data-testid="input-name" required />
              </div>
              <div>
                <Label className="text-xs">Email</Label>
                <Input type="email" value={formEmail} onChange={e => setFormEmail(e.target.value)} placeholder="email@example.com" className="mt-1 bg-background" data-testid="input-email" required />
              </div>
              <div>
                <Label className="text-xs">Plan</Label>
                <Select value={formPlan} onValueChange={setFormPlan}>
                  <SelectTrigger className="mt-1 bg-background" data-testid="select-plan">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="personal">Personal — $14.99/mo</SelectItem>
                    <SelectItem value="professional">Professional — $39.99/mo</SelectItem>
                    <SelectItem value="charter">Charter — $99.99/mo</SelectItem>
                  </SelectContent>
                </Select>
              </div>
              <Button type="submit" className="w-full" disabled={createMutation.isPending} data-testid="button-submit-subscriber">
                {createMutation.isPending ? "Adding..." : "Add Subscriber"}
              </Button>
            </form>
          </DialogContent>
        </Dialog>
      </div>

      {/* Filters */}
      <div className="flex items-center gap-3 flex-wrap">
        <div className="flex items-center gap-1 bg-muted/50 rounded-lg p-0.5">
          {filters.map(f => (
            <button
              key={f.key}
              onClick={() => setFilter(f.key)}
              className={`px-3 py-1.5 text-xs font-medium rounded-md transition-colors ${
                filter === f.key ? 'bg-primary text-primary-foreground' : 'text-muted-foreground hover:text-foreground'
              }`}
              data-testid={`filter-${f.key}`}
            >
              {f.label}
            </button>
          ))}
        </div>
        <div className="relative flex-1 max-w-xs">
          <Search className="absolute left-2.5 top-1/2 -translate-y-1/2 h-3.5 w-3.5 text-muted-foreground" />
          <Input type="search" placeholder="Search name or email..." value={search} onChange={e => setSearch(e.target.value)} className="pl-8 h-8 text-sm bg-muted/50 border-border" data-testid="input-search-subs" />
        </div>
        <span className="text-xs text-muted-foreground">{filtered.length} subscribers</span>
      </div>

      {/* Table */}
      {isLoading ? <Skeleton className="h-96 rounded-lg" /> : (
        <Card className="bg-card border-card-border overflow-hidden">
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-border bg-muted/30">
                  <th className="text-left px-4 py-2.5 text-xs font-semibold text-muted-foreground uppercase tracking-wider">Name</th>
                  <th className="text-left px-4 py-2.5 text-xs font-semibold text-muted-foreground uppercase tracking-wider">Email</th>
                  <th className="text-left px-4 py-2.5 text-xs font-semibold text-muted-foreground uppercase tracking-wider">Plan</th>
                  <th className="text-left px-4 py-2.5 text-xs font-semibold text-muted-foreground uppercase tracking-wider">Status</th>
                  <th className="text-left px-4 py-2.5 text-xs font-semibold text-muted-foreground uppercase tracking-wider">Agents</th>
                  <th className="text-left px-4 py-2.5 text-xs font-semibold text-muted-foreground uppercase tracking-wider">Monthly</th>
                  <th className="text-left px-4 py-2.5 text-xs font-semibold text-muted-foreground uppercase tracking-wider">Joined</th>
                </tr>
              </thead>
              <tbody>
                {filtered.slice(0, 50).map(s => (
                  <tr
                    key={s.id}
                    className="border-b border-border/50 hover:bg-muted/20 cursor-pointer transition-colors"
                    onClick={() => { setSelected(s); setDrawerOpen(true); }}
                    data-testid={`row-subscriber-${s.id}`}
                  >
                    <td className="px-4 py-2.5 text-sm font-medium text-foreground">{s.name}</td>
                    <td className="px-4 py-2.5 text-xs text-muted-foreground">{s.email}</td>
                    <td className="px-4 py-2.5"><PlanBadge plan={s.plan} /></td>
                    <td className="px-4 py-2.5"><StatusBadge status={s.status} /></td>
                    <td className="px-4 py-2.5 text-xs tabular-nums text-foreground">{s.agentsActive}</td>
                    <td className="px-4 py-2.5 text-xs tabular-nums text-foreground">${s.monthlySpend}</td>
                    <td className="px-4 py-2.5 text-xs text-muted-foreground">{new Date(s.joinedAt).toLocaleDateString([], { month: 'short', day: 'numeric', year: '2-digit' })}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          {filtered.length > 50 && (
            <div className="p-3 text-center text-xs text-muted-foreground border-t border-border">
              Showing 50 of {filtered.length} subscribers
            </div>
          )}
        </Card>
      )}

      <SubscriberDrawer
        subscriber={selected}
        open={drawerOpen}
        onClose={() => setDrawerOpen(false)}
        onToggleStatus={(id, newStatus) => statusMutation.mutate({ id, status: newStatus })}
        isToggling={statusMutation.isPending}
      />
    </div>
  );
}
