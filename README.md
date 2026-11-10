# APS 3 — Dossiê de Arquitetura Viva: Gestão de Perfis Energéticos

**Unidade Curricular:** Modelagem de Software · **Curso:** Engenharia de Software (4º Período — UniSenai)
**Projeto:** Smart Campus UniSenai · **Autor:** Henrique Chittolina · **Modalidade:** individual

## 1. Funcionalidade escolhida

**Gestão de Perfis Energéticos** — o mecanismo que traduz a mudança de ocupação de um Ambiente (laboratório/sala) em comandos de energia, conforme o Perfil Energético aplicado:

- **Iluminação:** reage de forma imediata (liga na entrada do primeiro usuário, desliga na saída do último).
- **Ar-condicionado:** permanece ligado por uma **janela de tolerância de 15 minutos (900 s)** após o Ambiente ficar vazio; se alguém entra e é autorizado na janela, o desligamento é cancelado.
- **Pré-condicionamento:** a Política de Agendamento antecipa a climatização quando há aula programada.

**Criticidade:** um erro aqui deixa energia ligada sem uso (desperdício) ou desliga equipamentos com o laboratório ocupado. O estado do Ambiente precisa ser protegido contra eventos fora de ordem, duplicados ou obsoletos.

### Regras de domínio utilizadas (Sprint 1)

| Regra | 
|---|
| Iluminação segue a ocupação sem tolerância |
| Ar-condicionado desliga somente após 15 min de ambiente vazio | 
| Sessão de Uso encerra apenas na saída do último usuário | 
| Atuadores só executam por decisão de ocupação/agendamento, nunca por conta própria |
| Ambiente só é "Ocupado" com Acesso validado (identidade + permissão) | 
| Estados do Ambiente: Vazio, Ocupado, Pré-condicionado | 

### Premissas adotadas nas lacunas do documento da Sprint 1

1. **Bancadas de computadores** não têm regra de tolerância definida (Seção 3.3): assumido desligamento imediato, configurável no `PerfilEnergeticoDTO`.
2. **Aula não concretizada** em Pré-condicionado tem comportamento indefinido (Seção 6.1): assumido retorno a Vazio com desligamento da climatização após prazo posterior ao início da aula.
3. **Contagem de presentes** (lacuna da Seção 2.3): assumido que o campo `presentes` vem no `OccupancyEventDTO`, calculado pelo Serviço de Acesso.
4. **Estado terminal `Desativado`** (descomissionamento do Ambiente) foi adicionado para atender ao requisito de estado terminal; não consta no documento da Sprint 1.
5. A validação de identidade e permissão ocorre **antes**, no Serviço de Acesso; este dossiê começa no `OccupancyEvent` já gerado.

## 2. Entidade principal e escopo dos diagramas

A entidade de domínio modelada na máquina de estados é o **Ambiente** (agregado). Os diagramas de sequência e atividades cobrem o fluxo de mudança de ocupação e a expiração da tolerância; o pré-condicionamento por agenda aparece na máquina de estados e no C4 (consulta ao Sistema de Grade Horária).

> Convenções Mermaid: `->>` = chamada síncrona bloqueante; `-)` = chamada assíncrona (mensageria); `-->>` = retorno com DTO. As raias do diagrama de atividades são `subgraph`; Fork/Join são barras pretas.

## 3. Artefato 1 — Diagrama de Sequência

```mermaid
sequenceDiagram
    autonumber
    participant SA as ServicoDeAcesso
    participant MQ as BarramentoEventos (RabbitMQ)
    participant OE as OrquestradorEnergia
    participant AMB as Ambiente (agregado)
    participant GP as GestorPerfilEnergetico
    participant TMP as TemporizadorTolerancia
    participant ATU as GatewayAtuadores

    %% ── Fase 1: mudança de ocupação → aplicação do Perfil Energético ──
    SA-)MQ: publicar("ocupacao.alterada", OccupancyEventDTO)
    Note over SA,MQ: Chamada assíncrona (AMQP) - ServicoDeAcesso não bloqueia
    MQ-)OE: tratarEventoOcupacao(OccupancyEventDTO)

    OE->>AMB: aplicarEvento(OccupancyEventDTO)
    AMB-->>OE: TransicaoDTO

    alt TransicaoDTO.aceita == true
        OE->>GP: resolverPerfil(ambienteId)
        GP-->>OE: PerfilEnergeticoDTO
        OE->>GP: calcularPlano(PerfilEnergeticoDTO, TransicaoDTO)
        GP-->>OE: PlanoEnergiaDTO

        par Comandos imediatos (iluminação e bancadas)
            loop para cada comando em PlanoEnergiaDTO.comandosImediatos
                OE->>ATU: executarComando(ComandoEnergiaDTO)
                ATU-->>OE: ResultadoComandoDTO
            end
        and Comandos diferidos (climatização com tolerância)
            loop para cada comando em PlanoEnergiaDTO.comandosDiferidos
                OE->>TMP: agendar(ComandoEnergiaDTO)
                TMP-)MQ: publicar("energia.atraso.900s", ComandoEnergiaDTO)
                TMP-->>OE: TimerDTO
            end
        and Cancelamento de tolerância pendente (reocupação)
            loop para cada toleranciaId em PlanoEnergiaDTO.timersACancelar
                OE->>TMP: cancelar(toleranciaId)
                TMP-->>OE: ConfirmacaoDTO
            end
        end

        opt algum ResultadoComandoDTO.sucesso == false
            OE-)MQ: publicar("energia.comando.falhou", FalhaComandoDTO)
        end
    else TransicaoDTO.aceita == false
        Note over OE,AMB: Estado protegido: evento incompatível com o estado atual não altera o Ambiente nem aciona atuadores
        OE-)MQ: publicar("energia.transicao.rejeitada", AlertaTransicaoDTO)
    end

    %% ── Fase 2: expiração da janela de tolerância (15 min) ──
    Note over MQ,OE: Após 900 s na fila de atraso, a mensagem é redirecionada pela DLX
    MQ-)OE: tratarToleranciaExpirada(TemporizadorExpiradoDTO)
    OE->>AMB: expirarTolerancia(TemporizadorExpiradoDTO)
    AMB-->>OE: TransicaoDTO

    alt TransicaoDTO.aceita == true
        OE->>ATU: executarComando(ComandoEnergiaDTO)
        ATU-->>OE: ResultadoComandoDTO
    else TransicaoDTO.aceita == false
        Note over OE,AMB: Ambiente reocupado ou toleranciaId obsoleto: expiração descartada
    end
```

**Operações públicas por linha de vida** (regra de consistência: toda mensagem recebida por uma linha de vida corresponde a uma operação abaixo):

```mermaid
classDiagram
    class IServicoDeAcesso {
        <<interface>>
        +publicarOcupacao(OccupancyEventDTO) void
    }
    class IBarramentoEventos {
        <<interface>>
        +publicar(topico String, mensagem Object) void
    }
    class IOrquestradorEnergia {
        <<interface>>
        +tratarEventoOcupacao(OccupancyEventDTO) void
        +tratarToleranciaExpirada(TemporizadorExpiradoDTO) void
    }
    class IAmbiente {
        <<interface>>
        +aplicarEvento(OccupancyEventDTO) TransicaoDTO
        +expirarTolerancia(TemporizadorExpiradoDTO) TransicaoDTO
    }
    class IGestorPerfilEnergetico {
        <<interface>>
        +resolverPerfil(ambienteId UUID) PerfilEnergeticoDTO
        +calcularPlano(PerfilEnergeticoDTO, TransicaoDTO) PlanoEnergiaDTO
    }
    class ITemporizadorTolerancia {
        <<interface>>
        +agendar(ComandoEnergiaDTO) TimerDTO
        +cancelar(toleranciaId UUID) ConfirmacaoDTO
    }
    class IGatewayAtuadores {
        <<interface>>
        +executarComando(ComandoEnergiaDTO) ResultadoComandoDTO
    }
    IServicoDeAcesso ..> IBarramentoEventos : publica
    IBarramentoEventos ..> IOrquestradorEnergia : entrega
    IOrquestradorEnergia ..> IAmbiente
    IOrquestradorEnergia ..> IGestorPerfilEnergetico
    IOrquestradorEnergia ..> ITemporizadorTolerancia
    IOrquestradorEnergia ..> IGatewayAtuadores
    ITemporizadorTolerancia ..> IBarramentoEventos : fila de atraso
```

**DTOs:**

| DTO | Campos principais |
|---|---|
| `OccupancyEventDTO` | `ambienteId`, `novoStatus` (OCUPADO/VAZIO), `presentes`, `origem` (ACESSO/SENSOR), `acessoValidado`, `timestamp` |
| `TransicaoDTO` | `aceita`, `estadoAnterior`, `estadoNovo`, `toleranciaId`, `toleranciaIdAnterior` |
| `PerfilEnergeticoDTO` | `perfilId`, `toleranciaClimatizacaoSegundos` (900), `toleranciaBancadasSegundos` (0), `janelaAntecipacaoMinutos` |
| `PlanoEnergiaDTO` | `comandosImediatos[]`, `comandosDiferidos[]`, `timersACancelar[]` |
| `ComandoEnergiaDTO` | `ambienteId`, `dispositivo` (ILUMINACAO/CLIMATIZACAO/BANCADAS), `acao` (LIGAR/DESLIGAR), `atrasoSegundos`, `toleranciaId` |
| `ResultadoComandoDTO` | `sucesso`, `dispositivo`, `erro` |
| `TimerDTO` / `ConfirmacaoDTO` | `timerId` (= `toleranciaId`) / `cancelado` |
| `TemporizadorExpiradoDTO` | `ambienteId`, `toleranciaId`, `comando` |
| `AlertaTransicaoDTO` / `FalhaComandoDTO` | `ambienteId`, `evento`, `motivo` / `comando`, `tentativas`, `erro` |

## 4. Artefato 2 — Diagrama de Atividades com Raias

```mermaid
flowchart TB
    classDef init fill:#000,stroke:#000,color:#000
    classDef fim fill:#fff,stroke:#000,stroke-width:4px,color:#fff
    classDef bar fill:#000,stroke:#000,color:#fff
    classDef dec fill:#fff8e1,stroke:#8d6e00,color:#000
    classDef acao fill:#e8f1fb,stroke:#2b5c97,color:#000

    subgraph R1["Raia 1 - Serviço de Acesso / Sensor de Presença (sistema externo ao fluxo)"]
        direction TB
        I1(( )):::init
        A1["Publicar OccupancyEventDTO<br/>BarramentoEventos.publicar()"]:::acao
    end

    subgraph R2["Raia 2 - Back-End: OrquestradorEnergia / Ambiente / GestorPerfilEnergetico"]
        direction TB
        B1["Receber evento<br/>OrquestradorEnergia.tratarEventoOcupacao()"]:::acao
        B2["Validar e aplicar transição<br/>Ambiente.aplicarEvento()"]:::acao
        D1{"Transição aceita?"}:::dec
        B3["Publicar alerta de transição rejeitada<br/>energia.transicao.rejeitada"]:::acao
        B4["Resolver Perfil Energético<br/>GestorPerfilEnergetico.resolverPerfil()"]:::acao
        B5["Calcular plano de comandos<br/>GestorPerfilEnergetico.calcularPlano()"]:::acao
        FK(["FORK"]):::bar
        B6["Despachar comandos imediatos<br/>(iluminação e bancadas)"]:::acao
        B7["Despachar comandos diferidos<br/>(climatização, atraso 900 s)"]:::acao
        B8["Solicitar cancelamento de tolerância<br/>(reocupação)"]:::acao
        JN(["JOIN"]):::bar
        D2{"Todos os comandos<br/>com sucesso?"}:::dec
        B9["Registrar plano aplicado"]:::acao
        B10["Publicar falha<br/>energia.comando.falhou"]:::acao
        F1((( ))):::fim
        F2((( ))):::fim
        F3((( ))):::fim
    end

    subgraph R3["Raia 3 - Serviço de Temporização: TemporizadorTolerancia + fila de atraso RabbitMQ"]
        direction TB
        T1["Enfileirar na fila de atraso<br/>TemporizadorTolerancia.agendar()"]:::acao
        T2["Invalidar tolerância pendente<br/>TemporizadorTolerancia.cancelar()"]:::acao
        I2(( )):::init
        T3["Evento de tempo: 900 s decorridos<br/>(TTL expirado, redirecionado pela DLX)"]:::acao
    end

    subgraph R4["Raia 4 - Hardware IoT: GatewayAtuadores / Atuadores"]
        direction TB
        H1["Comutar iluminação<br/>GatewayAtuadores.executarComando()"]:::acao
        H2["Comutar bancadas<br/>GatewayAtuadores.executarComando()"]:::acao
        H3["Desligar climatização<br/>GatewayAtuadores.executarComando()"]:::acao
    end

    %% ── Fluxo A: mudança de ocupação ──
    I1 --> A1
    A1 -. "assíncrono (AMQP)" .-> B1
    B1 --> B2
    B2 --> D1
    D1 -->|"[TransicaoDTO.aceita == false]"| B3
    B3 --> F1
    D1 -->|"[TransicaoDTO.aceita == true]"| B4
    B4 --> B5
    B5 --> FK
    FK --> B6
    FK --> B7
    FK --> B8
    B6 --> H1
    B6 --> H2
    B7 --> T1
    B8 --> T2
    H1 --> JN
    H2 --> JN
    T1 --> JN
    T2 --> JN
    JN --> D2
    D2 -->|"[todosSucesso == true]"| B9
    D2 -->|"[todosSucesso == false]"| B10
    B9 --> F2
    B10 --> F3

    %% ── Fluxo B: expiração da tolerância ──
    T1 -. "agenda timer" .-> I2
    I2 --> T3
    T3 -. "assíncrono (AMQP)" .-> C1

    subgraph R2B["Raia 2 (continuação) - Back-End: tratamento da expiração"]
        direction TB
        C1["Receber expiração<br/>OrquestradorEnergia.tratarToleranciaExpirada()"]:::acao
        C2["Validar toleranciaId e ocupação<br/>Ambiente.expirarTolerancia()"]:::acao
        D3{"Transição aceita?"}:::dec
        C3["Descartar expiração<br/>(ambiente reocupado ou id obsoleto)"]:::acao
        F4((( ))):::fim
        F5((( ))):::fim
    end

    C1 --> C2
    C2 --> D3
    D3 -->|"[TransicaoDTO.aceita == false]"| C3
    C3 --> F4
    D3 -->|"[TransicaoDTO.aceita == true]"| H3
    H3 --> F5
```

## 5. Artefato 3 — Diagrama de Transição de Estados (Ambiente)

```mermaid
stateDiagram-v2
    direction TB

    [*] --> Vazio : AmbienteCadastrado / inicializarAmbiente()

    state Vazio {
        direction TB
        [*] --> origemDaVacancia
        state origemDaVacancia <<choice>>
        origemDaVacancia --> ToleranciaClimatizacao : [origem == OCUPADO]
        origemDaVacancia --> ModoEconomico : [origem != OCUPADO]

        ModoEconomico : Modo Econômico
        ModoEconomico : entry / garantirDispositivosDesligados()

        ToleranciaClimatizacao : Tolerância do ar-condicionado
        ToleranciaClimatizacao : entry / gerarToleranciaId()
        ToleranciaClimatizacao : do / aguardar(toleranciaSegundos = 900)
        ToleranciaClimatizacao : exit / invalidarToleranciaId()

        ToleranciaClimatizacao --> ModoEconomico : TemporizadorExpirado [toleranciaId == vigente && presentes == 0] / desligarClimatizacao()
    }

    state PreCondicionado
    PreCondicionado : Pré-condicionado por agendamento
    PreCondicionado : entry / acionarClimatizacao()
    PreCondicionado : do / aguardarPrimeiroUsuario()

    state Ocupado
    Ocupado : Modo Operacional (Sessão de Uso ativa)
    Ocupado : entry / iniciarSessaoSeNecessario()
    Ocupado : do / monitorarConsumo()
    Ocupado : exit / desligarIluminacao()

    Vazio --> Ocupado : OccupancyEvent_OCUPADO [acessoValidado && presentes != 0] / iniciarSessao(), ligarIluminacao(), ligarClimatizacao()
    PreCondicionado --> Ocupado : OccupancyEvent_OCUPADO [acessoValidado && presentes != 0] / iniciarSessao(), ligarIluminacao()
    Ocupado --> Ocupado : OccupancyEvent_OCUPADO [sessaoAtiva && acessoValidado] / registrarPresenca()
    Ocupado --> Ocupado : SaidaParcial [presentes != 0] / registrarSaida()
    Ocupado --> Vazio : OccupancyEvent_VAZIO [presentes == 0] / encerrarSessao(), desligarBancadas()

    Vazio --> PreCondicionado : AulaProxima [aulaAgendada && dentroDaJanelaDeAntecipacao] / acionarClimatizacao()
    PreCondicionado --> Vazio : AulaNaoConcretizada [prazoAposInicioExpirado && presentes == 0] / desligarClimatizacao()

    Vazio --> Desativado : AmbienteDescomissionado [semSessaoAtiva] / desligarTodosOsDispositivos()
    PreCondicionado --> Desativado : AmbienteDescomissionado [semSessaoAtiva] / desligarTodosOsDispositivos()

    state Desativado
    Desativado : Ambiente fora de operação
    Desativado --> [*]
```

## 6. Artefato 4 — Visão de Contêineres C4 (Nível 2)

**C4-PlantUML** Imagem renderizada: [`c4-container.svg`](docs/architecture/c4-container.svg).

![C4 Nível 2](docs/architecture/c4-container.svg)

## 7. Artefato 5 — ADR 0001

[`docs/architecture/adr-0001.md`](docs/architecture/adr-0001.md) — *Temporização durável da janela de tolerância do ar-condicionado via RabbitMQ (TTL + Dead Letter Exchange)*. Status: Proposto.

## 8. Consistência entre os modelos

| Elemento | Sequência | Atividades | Estados | C4 |
|---|---|---|---|---|
| Recebe evento de ocupação | `tratarEventoOcupacao` | B1 | gatilho `OccupancyEvent_*` | Serviço de Energia ← Barramento (AMQP) |
| Valida transição no agregado | `Ambiente.aplicarEvento` | B2 / D1 | guardas `presentes`, `acessoValidado` | Serviço de Energia + PostgreSQL |
| Iluminação imediata / bancadas | `executarComando` (par/loop) | H1, H2 | `exit / desligarIluminacao()`, `desligarBancadas()` | gRPC → Gateway de Atuadores |
| Climatização com tolerância | `agendar` + `publicar(energia.atraso.900s)` | T1, B7 | `ToleranciaClimatizacao` (`do / aguardar(900)`) | fila de atraso no RabbitMQ |
| Cancelamento por reocupação | `cancelar(toleranciaId)` | T2, B8 | `exit / invalidarToleranciaId()` | Serviço de Energia |
| Expiração | `tratarToleranciaExpirada` / `expirarTolerancia` | C1, C2, D3 | `TemporizadorExpirado [...] / desligarClimatizacao()` | DLX → Serviço de Energia |
| Proteção contra estado inválido | `aceita == false` → `energia.transicao.rejeitada` | D1 → B3 | transições só nos pares de estado listados | — |
