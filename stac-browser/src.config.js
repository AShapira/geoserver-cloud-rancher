const config = require('../deployment.config');

export default Object.assign(config, CONFIG_CLI, window.STAC_BROWSER_CONFIG);
