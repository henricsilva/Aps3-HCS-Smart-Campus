@startuml c4-container-perfis-energeticos
' C4 Nível 2 (Contêineres) - Smart Campus UniSenai: Gestão de Perfis Energéticos
' Notação: C4-PlantUML (stdlib). Renderizar: java -jar plantuml.jar -tsvg workspace.dsl
!include <C4/C4_Container>

LAYOUT_WITH_LEGEND()
title Smart Campus UniSenai - Gestão de Perfis Energéticos (C4 Nível 2: Contêineres)

Person(gestor, "Gestor do Campus", "ADM que configura Perfis Energéticos e acompanha alertas")

System_Ext(grade, "Sistema de Grade Horária", "Fonte de verdade das aulas programadas por Ambiente")
System_Ext(infra, "Infraestrutura do Laboratório", "Leitores biométricos, sensores de presença/consumo e atuadores (iluminação, ar-condicionado, bancadas)")

System_Boundary(sc, "Smart Campus UniSenai") {
    Container(web, "Painel de Gestão", "React 18 + TypeScript (SPA)", "Cadastro de Ambientes e Perfis Energéticos; visualização de alertas")
    Container(api, "API de Gestão", "Node.js 22 + NestJS", "CRUD de Ambientes, Perfis Energéticos e Políticas de Agendamento")
    Container(acesso, "Serviço de Acesso", "Node.js 22 + NestJS", "Valida Credencial Biométrica e Permissão; registra Acesso; publica OccupancyEvent")
    Container(energia, "Serviço de Energia", "Node.js 22 + NestJS", "Contém OrquestradorEnergia, Ambiente (agregado), GestorPerfilEnergetico e TemporizadorTolerancia")
    Container(gateway, "Gateway de Atuadores", "Node.js 22 + MQTT.js", "Traduz ComandoEnergiaDTO em mensagens MQTT para os atuadores")
    ContainerQueue(broker, "Barramento de Eventos", "RabbitMQ 3.13 (AMQP 0-9-1)", "Exchange topic de eventos; filas de atraso com TTL + Dead Letter Exchange")
    ContainerDb(db, "Banco de Dados", "PostgreSQL 16", "Ambientes, Perfis, Sessões de Uso, Acessos (imutáveis), timers")
}

Rel(gestor, web, "Configura perfis e consulta alertas", "HTTPS")
Rel(web, api, "Chama", "REST/JSON sobre HTTPS")
Rel(api, db, "Lê e grava Perfis e Ambientes", "SQL/TLS (TCP 5432)")

Rel(infra, acesso, "Envia leituras biométricas e de presença", "MQTT 3.1.1 sobre TLS")
Rel(acesso, db, "Grava Acesso e Sessão de Uso", "SQL/TLS (TCP 5432)")
Rel(acesso, broker, "Publica OccupancyEvent (ocupacao.alterada)", "AMQP 0-9-1 (assíncrono)")

Rel(broker, energia, "Entrega OccupancyEvent e TemporizadorExpirado", "AMQP 0-9-1 (assíncrono)")
Rel(energia, broker, "Enfileira comando diferido (energia.atraso.900s) e publica alertas", "AMQP 0-9-1 (assíncrono)")
Rel(energia, db, "Persiste estado do Ambiente e lê Perfil Energético", "SQL/TLS (TCP 5432)")
Rel(energia, gateway, "executarComando(ComandoEnergiaDTO)", "gRPC sobre HTTP/2 (síncrono)")
Rel(energia, grade, "Consulta aulas para pré-condicionamento", "REST/JSON sobre HTTPS")
Rel(gateway, infra, "Liga/desliga iluminação, climatização e bancadas", "MQTT 3.1.1 sobre TLS")
@enduml
