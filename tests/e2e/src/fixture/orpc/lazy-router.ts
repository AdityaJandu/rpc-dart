import { os } from '@orpc/server';

export default os.router({
  ping: os.handler(() => 'pong'),
});