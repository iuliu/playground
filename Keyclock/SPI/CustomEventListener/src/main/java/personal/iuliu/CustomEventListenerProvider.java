package personal.iuliu;

import org.keycloak.events.Event;
import org.keycloak.events.EventListenerProvider;
import org.keycloak.events.admin.AdminEvent;
import lombok.extern.slf4j.Slf4j;
import lombok.NoArgsConstructor;
import personal.iuliu.utils.EventUtils;

@Slf4j
@NoArgsConstructor
public class CustomEventListenerProvider implements EventListenerProvider {

    @Override
    public void onEvent(Event event) {
      log.info("Caught user event {}", EventUtils.toString(event));
    }

    @Override
    public void onEvent(AdminEvent adminEvent, boolean b) {
        log.info("Caught admin event {}", EventUtils.toString(adminEvent));
		}

    @Override
    public void close() {

    }
}