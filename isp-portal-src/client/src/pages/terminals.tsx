import { useState } from "react";
import { useQuery, useMutation } from "@tanstack/react-query";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Skeleton } from "@/components/ui/skeleton";
import { Sheet, SheetContent, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle, AlertDialogTrigger } from "@/components/ui/alert-dialog";
import { Progress } from "@/components/ui/progress";
import { Search, Plus, Cpu, HardDrive, MemoryStick, Clock, Zap, Trash2, Loader2 } from "lucide-react";
import { apiRequest, queryClient } from "@/lib/queryClient";
import { useToast } from "@/hooks/use-toast";
import type { Terminal } from "@shared/schema";

type Filter = 'all' | 'online' | 'offline' | 'decommissioned' | 'tier1' | 'tier2';

function StatusBadge({ status }: { status: string }) {
  if (status === 'online') return <span className="bg-emerald-500/20 text-emerald-400 border border-emerald-500/30 rounded-full px-2 py-0.5 text-[10px] font-semibold">Online</span>;
  if (status === 'offline') return <span className="bg-red-500/20 text-red-400 border border-red-500/30 rounded-full px-2 py-0.5 text-[10px] font-semibold">Offline</span>;
  if (status === 'decommissioned') return <span className="bg-slate-500/20 text-slate-400 border border-slate-500/30 rounded-full px-2 py-0.5 text-[10px] font-semibold">Decommissioned</span>;
  return <span className="bg-amber-500/20 text-amber-400 border border-amber-500/30 rounded-full px-2 py-0.5 text-[10px] font-semibold">Provisioning</span>;
}

function TierBadge({ tier }: { tier: number }) {
  return (
    <Badge variant="outline" className={`text-xs ${tier === 1 ? 'border-primary/50 text-primary' : 'border-muted-foreground/30 text-muted-foreground'}`}>
      Tier {tier}
    </Badge>
  );
}

function TerminalDrawer({
  terminal,
  open,
  onClose,
  onDecommission,
  isDecommissioning,
}: {
  terminal: Terminal | null;
  open: boolean;
  onClose: () => void;
  onDecommission: (id: string) => void;
  isDecommissioning: boolean;
}) {
  if (!terminal) return null;
  const isDecommissioned = terminal.status === 'decommissioned';
  return (
    <Sheet open={open} onOpenChange={onClose}>
      <SheetContent className="bg-card border-l border-border w-[400px] sm:max-w-[400px] flex flex-col">
        <SheetHeader>
          <SheetTitle className="text-foreground" style={{ fontFamily: 'var(--font-display)' }}>{terminal.hostname}</SheetTitle>
          <div className="flex items-center gap-2 pt-1">
            <StatusBadge status={terminal.status} />
            <TierBadge tier={terminal.tier} />
          </div>
        </SheetHeader>
        <div className="mt-6 space-y-5 flex-1 overflow-y-auto">
          <div className="grid grid-cols-2 gap-4">
            <div>
              <p className="text-xs text-muted-foreground mb-1">IP Address</p>
              <p className="text-sm font-mono text-foreground">{terminal.ip}</p>
            </div>
            <div>
              <p className="text-xs text-muted-foreground mb-1">OS Version</p>
              <p className="text-sm text-foreground">{terminal.osVersion}</p>
            </div>
            <div>
              <p className="text-xs text-muted-foreground mb-1">Uptime</p>
              <p className="text-sm text-foreground flex items-center gap-1"><Clock className="h-3 w-3" />{terminal.uptime}</p>
            </div>
            <div>
              <p className="text-xs text-muted-foreground mb-1">Model</p>
              <p className="text-sm font-mono text-foreground">{terminal.modelLoaded}</p>
            </div>
          </div>

          <div className="space-y-3">
            <div>
              <div className="flex justify-between text-xs mb-1">
                <span className="text-muted-foreground flex items-center gap-1"><Cpu className="h-3 w-3" /> CPU</span>
                <span className="tabular-nums text-foreground">{terminal.cpuPercent}%</span>
              </div>
              <Progress value={terminal.cpuPercent} className="h-1.5" />
            </div>
            <div>
              <div className="flex justify-between text-xs mb-1">
                <span className="text-muted-foreground flex items-center gap-1"><MemoryStick className="h-3 w-3" /> RAM</span>
                <span className="tabular-nums text-foreground">{terminal.ramPercent}%</span>
              </div>
              <Progress value={terminal.ramPercent} className="h-1.5" />
            </div>
            <div>
              <div className="flex justify-between text-xs mb-1">
                <span className="text-muted-foreground flex items-center gap-1"><HardDrive className="h-3 w-3" /> Disk</span>
                <span className="tabular-nums text-foreground">{terminal.diskPercent}%</span>
              </div>
              <Progress value={terminal.diskPercent} className="h-1.5" />
            </div>
          </div>

          <div className="pt-2 border-t border-border">
            <div className="flex items-center gap-2 text-sm">
              <Zap className="h-4 w-4 text-primary" />
              <span className="text-muted-foreground">Last inference:</span>
              <span className="tabular-nums font-medium text-foreground">{terminal.lastInferenceTime}ms</span>
            </div>
          </div>
        </div>

        {/* Action footer */}
        <div className="border-t border-border pt-4 mt-4">
          {isDecommissioned ? (
            <p className="text-xs text-center text-muted-foreground py-1">This terminal has been decommissioned.</p>
          ) : (
            <AlertDialog>
              <AlertDialogTrigger asChild>
                <Button
                  variant="outline"
                  size="sm"
                  className="w-full gap-2 border-red-500/40 text-red-400 hover:bg-red-500/10"
                  disabled={isDecommissioning}
                  data-testid="button-decommission"
                >
                  {isDecommissioning
                    ? <Loader2 className="h-3.5 w-3.5 animate-spin" />
                    : <Trash2 className="h-3.5 w-3.5" />}
                  Decommission Terminal
                </Button>
              </AlertDialogTrigger>
              <AlertDialogContent className="bg-card border-border">
                <AlertDialogHeader>
                  <AlertDialogTitle style={{ fontFamily: 'var(--font-display)' }}>Decommission {terminal.hostname}?</AlertDialogTitle>
                  <AlertDialogDescription className="text-muted-foreground">
                    This marks the terminal as decommissioned and stops it from appearing in active counts.
                    The record is kept for audit purposes. This cannot be undone from the UI.
                  </AlertDialogDescription>
                </AlertDialogHeader>
                <AlertDialogFooter>
                  <AlertDialogCancel className="bg-muted border-border">Cancel</AlertDialogCancel>
                  <AlertDialogAction
                    className="bg-red-600 hover:bg-red-700 text-white"
                    onClick={() => onDecommission(terminal.id)}
                    data-testid="button-confirm-decommission"
                  >
                    Decommission
                  </AlertDialogAction>
                </AlertDialogFooter>
              </AlertDialogContent>
            </AlertDialog>
          )}
        </div>
      </SheetContent>
    </Sheet>
  );
}

export default function Terminals() {
  const [filter, setFilter] = useState<Filter>('all');
  const [search, setSearch] = useState('');
  const [selectedTerminal, setSelectedTerminal] = useState<Terminal | null>(null);
  const [drawerOpen, setDrawerOpen] = useState(false);
  const { toast } = useToast();

  const { data: terminals, isLoading } = useQuery<Terminal[]>({
    queryKey: ["/api/terminals"],
  });

  const decommissionMutation = useMutation({
    mutationFn: async (id: string) => {
      const res = await apiRequest("PATCH", `/api/terminals/${id}`, { status: 'decommissioned' });
      return res.json();
    },
    onSuccess: (updated: Terminal) => {
      queryClient.invalidateQueries({ queryKey: ["/api/terminals"] });
      setSelectedTerminal(updated);
      toast({ title: 'Terminal decommissioned', description: updated.hostname });
    },
    onError: () => {
      toast({ title: 'Failed to decommission terminal', variant: 'destructive' });
    },
  });

  // By default hide decommissioned unless explicitly filtered
  const filtered = (terminals || []).filter(t => {
    if (filter === 'all' && t.status === 'decommissioned') return false;
    if (filter === 'online' && t.status !== 'online') return false;
    if (filter === 'offline' && t.status !== 'offline') return false;
    if (filter === 'decommissioned' && t.status !== 'decommissioned') return false;
    if (filter === 'tier1' && t.tier !== 1) return false;
    if (filter === 'tier2' && t.tier !== 2) return false;
    if (search) {
      const q = search.toLowerCase();
      return t.hostname.toLowerCase().includes(q) || t.ip.includes(q);
    }
    return true;
  });

  const decommissionedCount = (terminals || []).filter(t => t.status === 'decommissioned').length;

  const filters: { key: Filter; label: string }[] = [
    { key: 'all', label: 'All' },
    { key: 'online', label: 'Online' },
    { key: 'offline', label: 'Offline' },
    { key: 'decommissioned', label: `Decommissioned${decommissionedCount > 0 ? ` (${decommissionedCount})` : ''}` },
    { key: 'tier1', label: 'Tier 1' },
    { key: 'tier2', label: 'Tier 2' },
  ];

  return (
    <div className="p-6 space-y-4" data-testid="terminals-page">
      <div className="flex items-center justify-between">
        <h1 className="text-lg font-semibold" style={{ fontFamily: 'var(--font-display)' }}>Terminals</h1>
        <Dialog>
          <DialogTrigger asChild>
            <Button size="sm" className="gap-1.5" data-testid="button-provision">
              <Plus className="h-3.5 w-3.5" /> Provision New Terminal
            </Button>
          </DialogTrigger>
          <DialogContent className="bg-card border-border">
            <DialogHeader>
              <DialogTitle style={{ fontFamily: 'var(--font-display)' }}>Provision New Terminal</DialogTitle>
            </DialogHeader>
            <div className="space-y-4 pt-2">
              <div className="bg-background rounded-lg p-4 border border-border">
                <p className="text-xs font-medium text-muted-foreground mb-2">PXE Boot Instructions</p>
                <ol className="text-sm text-foreground space-y-2 list-decimal list-inside">
                  <li>Connect terminal to network with DHCP enabled</li>
                  <li>Set BIOS to PXE boot priority</li>
                  <li>Terminal will auto-discover EtherOS provisioning server</li>
                  <li>OS image and model weights download automatically</li>
                </ol>
              </div>
              <div className="bg-background rounded-lg p-4 border border-border">
                <p className="text-xs font-medium text-muted-foreground mb-2">Config Endpoint</p>
                <code className="text-xs text-primary font-mono">https://provision.etheros.ai/api/v1/bootstrap</code>
              </div>
              <div className="bg-background rounded-lg p-4 border border-border">
                <p className="text-xs font-medium text-muted-foreground mb-2">API Key</p>
                <code className="text-xs text-primary font-mono">etheros_****************************aB3c</code>
              </div>
            </div>
          </DialogContent>
        </Dialog>
      </div>

      {/* Filters + Search */}
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
          <Input
            type="search"
            placeholder="Search hostname or IP..."
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="pl-8 h-8 text-sm bg-muted/50 border-border"
            data-testid="input-search"
          />
        </div>
        <span className="text-xs text-muted-foreground">{filtered.length} terminals</span>
      </div>

      {/* Table */}
      {isLoading ? (
        <Skeleton className="h-96 rounded-lg" />
      ) : (
        <Card className="bg-card border-card-border overflow-hidden">
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-border bg-muted/30">
                  <th className="text-left px-4 py-2.5 text-xs font-semibold text-muted-foreground uppercase tracking-wider">Hostname</th>
                  <th className="text-left px-4 py-2.5 text-xs font-semibold text-muted-foreground uppercase tracking-wider">IP Address</th>
                  <th className="text-left px-4 py-2.5 text-xs font-semibold text-muted-foreground uppercase tracking-wider">Tier</th>
                  <th className="text-left px-4 py-2.5 text-xs font-semibold text-muted-foreground uppercase tracking-wider">Status</th>
                  <th className="text-left px-4 py-2.5 text-xs font-semibold text-muted-foreground uppercase tracking-wider">Model</th>
                  <th className="text-left px-4 py-2.5 text-xs font-semibold text-muted-foreground uppercase tracking-wider">Last Seen</th>
                  <th className="text-left px-4 py-2.5 text-xs font-semibold text-muted-foreground uppercase tracking-wider">OS Version</th>
                </tr>
              </thead>
              <tbody>
                {filtered.map((t) => (
                  <tr
                    key={t.id}
                    className="border-b border-border/50 hover:bg-muted/20 cursor-pointer transition-colors"
                    onClick={() => { setSelectedTerminal(t); setDrawerOpen(true); }}
                    data-testid={`row-terminal-${t.id}`}
                  >
                    <td className="px-4 py-2.5 font-mono text-xs text-foreground font-medium">{t.hostname}</td>
                    <td className="px-4 py-2.5 font-mono text-xs text-muted-foreground">{t.ip}</td>
                    <td className="px-4 py-2.5"><TierBadge tier={t.tier} /></td>
                    <td className="px-4 py-2.5"><StatusBadge status={t.status} /></td>
                    <td className="px-4 py-2.5 font-mono text-xs text-muted-foreground">{t.modelVersion}</td>
                    <td className="px-4 py-2.5 text-xs text-muted-foreground">{new Date(t.lastSeen).toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' })}</td>
                    <td className="px-4 py-2.5 text-xs text-muted-foreground">{t.osVersion}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </Card>
      )}

      <TerminalDrawer
        terminal={selectedTerminal}
        open={drawerOpen}
        onClose={() => setDrawerOpen(false)}
        onDecommission={(id) => decommissionMutation.mutate(id)}
        isDecommissioning={decommissionMutation.isPending}
      />
    </div>
  );
}
