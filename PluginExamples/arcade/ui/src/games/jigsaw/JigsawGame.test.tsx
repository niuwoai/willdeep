import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it } from 'vitest';
import { I18nProvider } from '../../core/i18n';
import JigsawGame from '.';

function renderGame() {
  return render(
    <I18nProvider>
      <JigsawGame seed="jigsaw-ui" />
    </I18nProvider>,
  );
}

describe('图片拼图集成', () => {
  it('先展示三张内置图片，选中后才出现 3×3 棋盘', async () => {
    const user = userEvent.setup();
    renderGame();
    expect(screen.getByTestId('jigsaw-picker')).toBeInTheDocument();
    expect(screen.getAllByRole('img')).toHaveLength(3);
    expect(screen.queryByTestId('jigsaw-board')).not.toBeInTheDocument();

    await user.click(screen.getByTestId('jigsaw-image-lighthouse'));
    expect(await screen.findByTestId('jigsaw-board')).toBeInTheDocument();
    expect(screen.getAllByTestId('jigsaw-piece')).toHaveLength(9);
    expect(screen.getByTestId('jigsaw-stage')).toHaveTextContent('3×3');
  });

  it('点选两块会交换并增加交换次数', async () => {
    const user = userEvent.setup();
    renderGame();
    await user.click(screen.getByTestId('jigsaw-image-railway'));
    const pieces = await screen.findAllByTestId('jigsaw-piece');
    const firstPiece = pieces[0]?.getAttribute('data-piece');
    const secondPiece = pieces[1]?.getAttribute('data-piece');
    await user.click(pieces[0] as HTMLElement);
    await user.click(pieces[1] as HTMLElement);
    const after = screen.getAllByTestId('jigsaw-piece');
    expect(after[0]).toHaveAttribute('data-piece', secondPiece);
    expect(after[1]).toHaveAttribute('data-piece', firstPiece);
    expect(screen.getByTestId('jigsaw-moves')).toHaveTextContent('1');
  });

  it('可展开原图，也能返回选图页', async () => {
    const user = userEvent.setup();
    renderGame();
    await user.click(screen.getByTestId('jigsaw-image-greenhouse'));
    await user.click(await screen.findByTestId('jigsaw-preview-toggle'));
    expect(screen.getByTestId('jigsaw-preview')).toBeInTheDocument();
    await user.click(screen.getByTestId('jigsaw-change-image'));
    await waitFor(() => expect(screen.getByTestId('jigsaw-picker')).toBeInTheDocument());
  });
});
