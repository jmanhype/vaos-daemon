import type { Approval } from "$lib/api/types";

class ApprovalsStore {
  approvals = $state<Approval[]>([]);
  loading = $state(false);
  error = $state<string | null>(null);

  pendingCount = $derived(
    this.approvals.filter((a) => a.status === "pending").length,
  );

  pendingApprovals = $derived(
    this.approvals.filter((a) => a.status === "pending"),
  );

  async fetchApprovals(): Promise<void> {
    this.loading = true;
    this.error = null;
    try {
      const res = await fetch("http://127.0.0.1:9089/api/v1/approvals");
      if (!res.ok) throw new Error("Failed to fetch");
      const data = await res.json();
      this.approvals = data.approvals ?? [];
    } catch (err) {
      this.error =
        err instanceof Error ? err.message : "Failed to fetch approvals";
    } finally {
      this.loading = false;
    }
  }

  async approve(id: number, notes: string): Promise<void> {
    await fetch(`http://127.0.0.1:9089/api/v1/approvals/${id}/approve`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ notes, resolved_by: "operator" }),
    });
    await this.fetchApprovals();
  }

  async reject(id: number, notes: string): Promise<void> {
    await fetch(`http://127.0.0.1:9089/api/v1/approvals/${id}/reject`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ notes, resolved_by: "operator" }),
    });
    await this.fetchApprovals();
  }

  async requestRevision(id: number, notes: string): Promise<void> {
    await fetch(
      `http://127.0.0.1:9089/api/v1/approvals/${id}/request-revision`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ notes, resolved_by: "operator" }),
      },
    );
    await this.fetchApprovals();
  }
}

export const approvalsStore = new ApprovalsStore();
