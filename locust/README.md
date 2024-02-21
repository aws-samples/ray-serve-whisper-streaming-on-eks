Locust load testing
===

The `locustfile.py` is implemented with `websockets` to test the Whisper streaming application in Websocket protocol. 

## Setup
```bash
pip install -r requirements.txt
```

## Run
### Run with Locust's web interface

```bash
locust -f locustfile.py
```

Then open `http://localhost:8089`

### Headless run
```
locust --headless -u 1 -f locustfile.py
```

By default, it connects to `ws://localhost:8765`. If you need to connect to a diffferent host, you can either override it within the code or specify the host by providing the `--host` option.
For more usage, refer to this [doc](https://docs.locust.io/en/stable/configuration.html).

