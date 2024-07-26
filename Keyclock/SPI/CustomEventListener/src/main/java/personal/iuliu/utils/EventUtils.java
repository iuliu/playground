package com.dcmsys.keycloak.extensions.events.logging.utils;

import java.util.Map;
import org.keycloak.events.admin.AdminEvent;
import org.keycloak.events.Event;
import lombok.experimental.UtilityClass;

@UtilityClass
public class EventUtils {

    public static String toString(AdminEvent adminEvent) {
        StringBuilder sb = new StringBuilder();

        sb.append("operationType=").append(adminEvent.getOperationType());
        sb.append(", realmId=").append(adminEvent.getAuthDetails().getRealmId());
        sb.append(", clientId=").append(adminEvent.getAuthDetails().getClientId());
        sb.append(", userId=").append(adminEvent.getAuthDetails().getUserId());
        sb.append(", ipAddress=").append(adminEvent.getAuthDetails().getIpAddress());
        sb.append(", resourcePath=").append(adminEvent.getResourcePath());
        sb.append(", representation=").append(adminEvent.getRepresentation());

        if (adminEvent.getError() != null) {
            sb.append(", error=").append(adminEvent.getError());
        }
        return sb.toString();
    }

    public static String toString(Event event) {
        StringBuilder sb = new StringBuilder();

        sb.append("type=").append(event.getType());
        sb.append(", realmId=").append(event.getRealmId());
        sb.append(", clientId=").append(event.getClientId());
        sb.append(", userId=").append(event.getUserId());
        sb.append(", ipAddress=").append(event.getIpAddress());

        if (event.getError() != null) {
            sb.append(", error=").append(event.getError());
        }

        if (event.getDetails() != null) {
            for (Map.Entry<String, String> e : event.getDetails().entrySet()) {
                sb.append(", ").append(e.getKey());
                if (e.getValue() == null || e.getValue().indexOf(' ') == -1) {
                    sb.append("=").append(e.getValue());
                } else {
                    sb.append("='").append(e.getValue()).append("'");
                }
            }
        }
        return sb.toString();
    }
}