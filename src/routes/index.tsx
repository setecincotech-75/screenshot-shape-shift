import { createFileRoute } from "@tanstack/react-router";

export const Route = createFileRoute("/")({
  head: () => ({
    meta: [
      { title: "Curso de Máquinas Pesadas · Sistema Nacional de Apoio ao Campo" },
      { name: "description", content: "Plataforma do curso avançado de operação de máquinas pesadas 2026 para professores e alunos." },
      { property: "og:title", content: "Curso de Máquinas Pesadas 2026" },
      { property: "og:description", content: "Área do professor e do aluno do curso de operação de máquinas pesadas." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary_large_image" },
    ],
  }),
  component: Index,
});

function Index() {
  return (
    <iframe
      src="/curso.html"
      title="Curso de Máquinas Pesadas"
      className="fixed inset-0 h-screen w-screen border-0"
    />
  );
}
