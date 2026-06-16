"use client";

import { useDroppable } from "@dnd-kit/core";

interface ColumnProps {
  id: string;
  title: string;
  children: React.ReactNode;
}

export function Column({ id, title, children }: ColumnProps) {
  const { setNodeRef } = useDroppable({
    id: id,
  });

  return (
    <div className="flex w-80 flex-col gap-4 rounded-lg bg-muted/50 p-4">
      <div className="flex items-center justify-between">
        <h3 className="font-semibold">{title}</h3>
      </div>
      <div ref={setNodeRef} className="flex flex-1 flex-col gap-2 min-h-[200px]">
        {children}
      </div>
    </div>
  );
}
