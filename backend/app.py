from flask import Flask
from flask_cors import CORS

# Create a new Flask web server
app = Flask(__name__)
# Enable Cross-Origin Resource Sharing (CORS)
CORS(app)

# Create a new route for the root URL ('/')
@app.route("/")
def hello():
    """Return a simple 'hello' message."""
    return "Hello from the Python Backend API!"

# The main entry point for the application
if __name__ == '__main__':
    # Run the app on host 0.0.0.0 (accessible from outside the container)
    # and on port 80, which is the standard HTTP port.
    app.run(host='0.0.0.0', port=80)